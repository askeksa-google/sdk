// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:kernel/ast.dart';
import 'package:kernel/type_environment.dart';
import 'package:kernel/visitor.dart';

import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/dispatch_table.dart';
import 'package:dart2wasm/intrinsics.dart';
import 'package:dart2wasm/translator.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class HasThis extends RecursiveVisitor {
  bool found = false;

  bool hasThis(TreeNode node) {
    found = false;
    node.accept(this);
    return found;
  }

  void visitThisExpression(ThisExpression node) {
    found = true;
  }
}

class CodeGenerator extends Visitor<void> with VisitorVoidMixin {
  Translator translator;

  late Member member;
  late StaticTypeContext typeContext;
  late List<w.Local> paramLocals;
  w.Label? returnLabel;

  Map<VariableDeclaration, w.Local> locals = {};
  w.Local? thisLocal;
  late w.DefinedFunction function;
  late w.Instructions b;

  CodeGenerator(this.translator);

  ClassInfo get object => translator.classes[0];

  void defaultNode(Node node) {
    throw "Not supported: ${node.runtimeType}";
  }

  void defaultTreeNode(TreeNode node) {
    throw "Not supported: ${node.runtimeType}";
  }

  void generate(Member member, w.DefinedFunction function,
      {List<w.Local>? inlinedLocals, w.Label? returnLabel}) {
    if (member.isExternal) {
      print("External member: $member");
      return;
    }

    this.member = member;
    typeContext = StaticTypeContext(member, translator.typeEnvironment);
    paramLocals = inlinedLocals ?? function.locals;
    this.returnLabel = returnLabel;

    List<VariableDeclaration> params = member.function.positionalParameters;
    int implicitParams = paramLocals.length - params.length;
    assert(implicitParams == 0 || implicitParams == 1);
    for (int i = 0; i < params.length; i++) {
      locals[params[i]] = paramLocals[implicitParams + i];
    }

    this.function = function;
    b = function.body;
    if (member is Constructor) {
      ClassInfo info = translator.classInfo[member.enclosingClass]!;
      thisLocal = paramLocals[0];
      Class cls = member.enclosingClass;
      for (Field field in cls.fields) {
        if (field.isInstanceMember && field.initializer != null) {
          int fieldIndex = translator.fieldIndex[field]!;
          b.local_get(thisLocal!);
          field.initializer!.accept(this);
          b.struct_set(info.struct, fieldIndex);
        }
      }
      visitList(member.initializers, this);
    } else if (implicitParams == 1) {
      ClassInfo info = translator.classInfo[member.enclosingClass]!;
      if ((paramLocals[0].type as w.RefType).heapType == info.repr.heapType ||
          !HasThis().hasThis(member.function.body)) {
        thisLocal = paramLocals[0];
      } else {
        thisLocal = function.addLocal(info.repr);
        b.local_get(paramLocals[0]);
        b.global_get(info.rtt);
        b.ref_cast();
        b.local_set(thisLocal!);
      }
    } else {
      thisLocal = null;
    }
    member.function.body.accept(this);
    b.end();
  }

  void _call(Member target) {
    w.BaseFunction targetFunction = translator.functions[target]!;
    if (translator.shouldInline(target)) {
      List<w.Local> inlinedLocals = targetFunction.type.inputs
          .map((t) => function.addLocal(t.withNullability(true)))
          .toList();
      for (w.Local local in inlinedLocals.reversed) {
        b.local_set(local);
      }
      w.Label block = b.block([], targetFunction.type.outputs);
      CodeGenerator(translator).generate(target, function,
          inlinedLocals: inlinedLocals, returnLabel: block);
    } else {
      b.call(targetFunction);
    }
  }

  void visitFieldInitializer(FieldInitializer node) {
    w.StructType struct = translator
        .classInfo[(node.parent as Constructor).enclosingClass]!.struct;
    int fieldIndex = translator.fieldIndex[node.field]!;

    b.local_get(thisLocal!);
    node.value.accept(this);
    b.struct_set(struct, fieldIndex);
  }

  void visitSuperInitializer(SuperInitializer node) {
    if ((node.parent as Constructor).enclosingClass.superclass?.superclass ==
        null) {
      return;
    }
    b.local_get(thisLocal!);
    if (translator.optionParameterNullability && thisLocal!.type.nullable) {
      b.ref_as_non_null();
    }
    _visitArguments(node.arguments, node.target.function);
    _call(node.target!);
  }

  void visitBlock(Block node) {
    node.visitChildren(this);
  }

  void visitBlockExpression(BlockExpression node) {
    node.visitChildren(this);
  }

  void visitVariableDeclaration(VariableDeclaration node) {
    w.ValueType type = translator.translateType(node.type);
    w.Local local = function.addLocal(type.withNullability(true));
    locals[node] = local;
    if (node.initializer != null) {
      node.initializer!.accept(this);
      b.local_set(local);
    }
  }

  void visitEmptyStatement(EmptyStatement node) {}

  void visitExpressionStatement(ExpressionStatement node) {
    _visitVoidExpression(node.expression);
  }

  void _visitVoidExpression(Expression exp) {
    exp.accept(this);
    if (exp.getStaticType(typeContext) is! VoidType) {
      b.drop();
    }
  }

  bool _hasLogicalOperator(Expression condition) {
    while (condition is Not) condition = condition.operand;
    return condition is LogicalExpression;
  }

  void _branchIf(Expression condition, w.Label target,
      {required bool negated}) {
    while (condition is Not) {
      negated = !negated;
      condition = condition.operand;
    }
    if (condition is LogicalExpression) {
      bool isConjunctive =
          (condition.operatorEnum == LogicalExpressionOperator.AND) ^ negated;
      if (isConjunctive) {
        w.Label conditionBlock = b.block();
        _branchIf(condition.left, conditionBlock, negated: !negated);
        _branchIf(condition.right, target, negated: negated);
        b.end();
      } else {
        _branchIf(condition.left, target, negated: negated);
        _branchIf(condition.right, target, negated: negated);
      }
    } else {
      condition.accept(this);
      if (negated) {
        b.i32_eqz();
      }
      b.br_if(target);
    }
  }

  void _conditional(Expression condition, TreeNode then, TreeNode? otherwise,
      List<w.ValueType> result) {
    if (!_hasLogicalOperator(condition)) {
      // Simple condition
      condition.accept(this);
      b.if_(const [], result);
      then.accept(this);
      if (otherwise != null) {
        b.else_();
        otherwise.accept(this);
      }
      b.end();
    } else {
      // Complex condition
      w.Label ifBlock = b.block(const [], result);
      if (otherwise != null) {
        w.Label elseBlock = b.block();
        _branchIf(condition, elseBlock, negated: true);
        then.accept(this);
        b.br(ifBlock);
        b.end();
        otherwise.accept(this);
      } else {
        _branchIf(condition, ifBlock, negated: true);
        then.accept(this);
      }
      b.end();
    }
  }

  void visitIfStatement(IfStatement node) {
    _conditional(node.condition, node.then, node.otherwise, const []);
  }

  void visitDoStatement(DoStatement node) {
    w.Label loop = b.loop();
    node.body.accept(this);
    _branchIf(node.condition, loop, negated: false);
    b.end();
  }

  void visitWhileStatement(WhileStatement node) {
    w.Label block = b.block();
    w.Label loop = b.loop();
    _branchIf(node.condition, block, negated: true);
    node.body.accept(this);
    b.br(loop);
    b.end();
    b.end();
  }

  void visitForStatement(ForStatement node) {
    visitList(node.variables, this);
    w.Label block = b.block();
    w.Label loop = b.loop();
    _branchIf(node.condition, block, negated: true);
    node.body.accept(this);
    for (Expression update in node.updates) {
      _visitVoidExpression(update);
    }
    b.br(loop);
    b.end();
    b.end();
  }

  void visitReturnStatement(ReturnStatement node) {
    Expression? expression = node.expression;
    if (expression != null) {
      _visitArgument(expression, member.function!.returnType);
    }
    if (returnLabel != null) {
      b.br(returnLabel!);
    } else {
      b.return_();
    }
  }

  void visitLet(Let node) {
    node.visitChildren(this);
  }

  void visitThisExpression(ThisExpression node) {
    b.local_get(thisLocal!);
  }

  void visitConstructorInvocation(ConstructorInvocation node) {
    ClassInfo info = translator.classInfo[node.target.enclosingClass]!;
    w.Local temp = function.addLocal(info.repr);
    b.global_get(info.rtt);
    b.struct_new_default_with_rtt(info.struct);
    b.local_tee(temp);
    b.i32_const(info.classId);
    b.struct_set(info.struct, 0);
    b.local_get(temp);
    if (translator.optionParameterNullability) {
      b.ref_as_non_null();
    }
    _visitArguments(node.arguments, node.target.function);
    _call(node.target);
    b.local_get(temp);
  }

  void visitStaticInvocation(StaticInvocation node) {
    Intrinsic? intrinsic = translator.intrinsics.getStaticIntrinsic(node, this);
    if (intrinsic != null) {
      intrinsic(this);
      return;
    }
    _visitArguments(node.arguments, node.target.function);
    if (node.target == translator.coreTypes.identicalProcedure) {
      // TODO: Check for reference types
      b.ref_eq();
      return;
    }
    _call(node.target);
  }

  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    b.local_get(thisLocal!);
    if (translator.optionParameterNullability && thisLocal!.type.nullable) {
      b.ref_as_non_null();
    }
    _visitArguments(node.arguments, node.interfaceTarget.function);
    _call(node.interfaceTarget);
  }

  void visitInstanceInvocation(InstanceInvocation node) {
    Member target = node.interfaceTarget;
    _visitArgument(node.receiver, node.receiver.getStaticType(typeContext));
    if (target is! Procedure) {
      throw "Unsupported invocation of $target";
    }
    if (target.kind == ProcedureKind.Operator) {
      _visitArguments(node.arguments, node.interfaceTarget.function);
      Intrinsic? intrinsic =
          translator.intrinsics.getOperatorIntrinsic(node, this);
      if (intrinsic != null) {
        intrinsic(this);
        return;
      }
    }
    _virtualCall(target, node.arguments, getter: false, setter: false);
  }

  void visitEqualsCall(EqualsCall node) {
    Intrinsic? intrinsic = translator.intrinsics.getEqualsIntrinsic(node, this);
    if (intrinsic != null) {
      node.left.accept(this);
      node.right.accept(this);
      intrinsic(this);
      return;
    }
    // TODO: virtual call
    node.left.accept(this);
    node.right.accept(this);
    b.ref_eq();
    if (node.isNot) {
      b.i32_eqz();
    }

    if (false)
      throw "EqualsCall of types "
          "${node.left.getStaticType(typeContext)} and "
          "${node.right.getStaticType(typeContext)} not supported";
  }

  void visitEqualsNull(EqualsNull node) {
    node.expression.accept(this);
    b.ref_is_null();
    if (node.isNot) {
      b.i32_eqz();
    }
  }

  void _virtualCall(Procedure interfaceTarget, Arguments arguments,
      {required bool getter, required bool setter}) {
    Member? singleTarget = translator.subtypes
        .getSingleTargetForInterfaceInvocation(interfaceTarget, setter: setter);
    if (singleTarget != null) {
      _visitArguments(arguments, singleTarget.function);
      _call(singleTarget);
      return;
    }

    int selectorId = getter
        ? translator.tableSelectorAssigner.getterSelectorId(interfaceTarget)
        : translator.tableSelectorAssigner
            .methodOrSetterSelectorId(interfaceTarget);
    SelectorInfo selector = translator.dispatchTable.selectorInfo[selectorId]!;

    // Receiver is already on stack.
    w.Local receiver =
        function.addLocal(w.RefType.def(object.struct, nullable: true));
    b.local_tee(receiver);
    _visitArguments(arguments, interfaceTarget.function);

    if (translator.optionPolymorphicSpecialization) {
      return _polymorphicSpecialization(selector, receiver);
    }

    b.i32_const(selector.offset);
    b.local_get(receiver);
    b.struct_get(object.struct, 0);
    b.i32_add();
    b.call_indirect(selector.signature);
  }

  void _polymorphicSpecialization(SelectorInfo selector, w.Local receiver) {
    Map<int, Procedure> implementations = Map.from(selector.classes);
    implementations.removeWhere((id, target) => target.isAbstract);

    w.Local idVar = function.addLocal(w.NumType.i32);
    b.local_get(receiver);
    b.struct_get(object.struct, 0);
    b.local_set(idVar);

    w.Label block =
        b.block(selector.signature.inputs, selector.signature.outputs);
    calls:
    while (Set.from(implementations.values).length > 1) {
      for (int id in implementations.keys) {
        Procedure target = implementations[id]!;
        if (implementations.values.where((t) => t == target).length == 1) {
          // Single class id implements method.
          b.local_get(idVar);
          b.i32_const(id);
          b.i32_eq();
          b.if_(selector.signature.inputs, selector.signature.inputs);
          _call(target);
          b.br(block);
          b.end();
          implementations.remove(id);
          continue calls;
        }
      }
      // Find class id that separates remaining classes in two.
      List<int> sorted = implementations.keys.toList()..sort();
      int pivotId = sorted.firstWhere(
          (id) => implementations[id] != implementations[sorted.first]);
      // Fail compilation if no such id exists.
      assert(sorted.lastWhere(
              (id) => implementations[id] != implementations[pivotId]) ==
          pivotId - 1);
      Procedure target = implementations[sorted.first]!;
      b.local_get(idVar);
      b.i32_const(pivotId);
      b.i32_lt_u();
      b.if_(selector.signature.inputs, selector.signature.inputs);
      _call(target);
      b.br(block);
      b.end();
      for (int id in sorted) {
        if (id == pivotId) break;
        implementations.remove(id);
      }
      continue calls;
    }
    // Call remaining implementation.
    Procedure target = implementations.values.first;
    _call(target);
    b.end();
  }

  @override
  void visitVariableGet(VariableGet node) {
    w.Local? local = locals[node.variable];
    if (local == null) {
      throw "Read of undefined variable $node";
    }
    b.local_get(local);
  }

  @override
  void visitVariableSet(VariableSet node) {
    w.Local? local = locals[node.variable];
    if (local == null) {
      throw "Read of undefined variable $node";
    }
    node.value.accept(this);
    b.local_tee(local);
  }

  @override
  void visitInstanceGet(InstanceGet node) {
    Member target = node.interfaceTarget;
    if (target is Field) {
      node.receiver.accept(this);
      w.StructType struct = translator.classInfo[target.enclosingClass]!.struct;
      int fieldIndex = translator.fieldIndex[target]!;
      //b.rtt_canon(w.HeapType.def(struct));
      //b.ref_cast(w.HeapType.any, w.HeapType.def(struct));
      b.struct_get(struct, fieldIndex);
      return;
    } else if (target is Procedure && target.isGetter) {
      node.receiver.accept(this);
      _virtualCall(target, Arguments([]), getter: true, setter: false);
      return;
    }
    throw "InstanceGet of non-Field/Getter $target not supported";
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    Member target = node.interfaceTarget;
    if (target is Field) {
      node.receiver.accept(this);
      w.StructType struct = translator.classInfo[target.enclosingClass]!.struct;
      int fieldIndex = translator.fieldIndex[target]!;
      //b.rtt_canon(w.HeapType.def(struct));
      //b.ref_cast(w.HeapType.any, w.HeapType.def(struct));
      w.Local temp = function.addLocal(struct.fields[fieldIndex].type.unpacked);
      node.value.accept(this);
      b.local_tee(temp);
      b.struct_set(struct, fieldIndex);
      b.local_get(temp);
      return;
    }
    throw "InstanceSet of non-Field $target not supported";
  }

  void visitLogicalExpression(LogicalExpression node) {
    _conditional(
        node, BoolLiteral(true), BoolLiteral(false), const [w.NumType.i32]);
  }

  void visitNot(Not node) {
    node.operand.accept(this);
    b.i32_eqz();
  }

  void visitConditionalExpression(ConditionalExpression node) {
    w.ValueType type =
        translator.translateType(node.getStaticType(typeContext));
    _conditional(node.condition, node.then, node.otherwise, [type]);
  }

  void visitNullCheck(NullCheck node) {
    node.operand.accept(this);
  }

  void _visitArguments(Arguments node, FunctionNode function) {
    for (int i = 0; i < node.positional.length; i++) {
      _visitArgument(node.positional[i], function.positionalParameters[i].type);
    }
    for (NamedExpression arg in node.named) {
      _visitArgument(arg.value,
          function.namedParameters.firstWhere((p) => p.name == arg.name).type);
    }
  }

  void _visitArgument(Expression node, DartType paramType) {
    node.accept(this);
    if (translator.optionParameterNullability &&
        !paramType.isPotentiallyNullable &&
        translator.translateType(node.getStaticType(typeContext))
            is w.RefType) {
      b.ref_as_non_null();
    }
  }

  void visitConstantExpression(ConstantExpression node) {
    node.constant.accept(this);
  }

  void visitBoolLiteral(BoolLiteral node) {
    b.i32_const(node.value ? 1 : 0);
  }

  void visitIntLiteral(IntLiteral node) {
    b.i64_const(node.value);
  }

  void visitIntConstant(IntConstant node) {
    b.i64_const(node.value);
  }

  void visitDoubleLiteral(DoubleLiteral node) {
    b.f64_const(node.value);
  }

  void visitAsExpression(AsExpression node) {
    node.operand.accept(this);
    // TODO: Check
  }

  void visitNullLiteral(NullLiteral node) {
    TreeNode parent = node.parent;
    DartType type;
    if (parent is VariableDeclaration) {
      type = parent.type;
    } else if (parent is VariableSet) {
      type = parent.variable.type;
    } else if (parent is InstanceSet) {
      Member target = parent.interfaceTarget;
      type = target is Field
          ? target.type
          : target.function.positionalParameters.single.type;
    } else if (parent is Field) {
      type = parent.type;
    } else if (parent is FieldInitializer) {
      type = parent.field.type;
    } else if (parent is ReturnStatement) {
      type = member.function!.returnType;
    } else if (parent is AsExpression) {
      type = parent.type;
    } else {
      throw "Unsupported null literal context: $parent";
    }
    w.ValueType wasmType = translator.translateType(type);
    w.HeapType heapType =
        wasmType is w.RefType ? wasmType.heapType : w.HeapType.any;
    b.ref_null(heapType);
  }
}
