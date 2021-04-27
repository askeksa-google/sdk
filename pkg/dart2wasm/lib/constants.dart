// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';
import 'package:kernel/visitor.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class ConstantInfo {
  Constant constant;
  w.Global global;
  w.DefinedFunction function;

  ConstantInfo(this.constant, this.global, this.function);
}

typedef ConstantCodeGenerator = void Function(w.DefinedFunction);

class Constants {
  final Translator translator;
  final Map<Constant, ConstantInfo> constantInfo = {};

  Constants(this.translator);

  void instantiateConstant(w.DefinedFunction function, Constant constant,
      w.ValueType? expectedType) {
    constant.accept(ConstantInstantiator(this, function, expectedType));
  }
}

class ConstantInstantiator extends ConstantVisitor<void> {
  final Constants constants;
  final w.DefinedFunction function;
  final w.ValueType? expectedType;

  ConstantInstantiator(this.constants, this.function, this.expectedType);

  Translator get translator => constants.translator;
  w.Module get m => translator.m;

  void instantiateLazyConstant(
      Constant constant, w.RefType type, ConstantCodeGenerator generator) {
    assert(!type.nullable);
    ConstantInfo? info = constants.constantInfo[constant];
    if (info == null) {
      w.DefinedGlobal global =
          m.addGlobal(w.GlobalType(type.withNullability(true)));
      global.initializer.ref_null(type.heapType);
      global.initializer.end();
      w.FunctionType ftype = m.addFunctionType([], [type]);
      w.DefinedFunction function = m.addFunction(ftype);
      generator(function);
      w.Instructions b = function.body;
      b.global_set(global);
      b.global_get(global);
      b.ref_as_non_null();
      b.end();
      info = ConstantInfo(constant, global, function);
      constants.constantInfo[constant] = info;
    }
    w.Instructions b = function.body;
    w.Label b1 = b.block([], [type]);
    w.Label b2 = b.block([], []);
    b.global_get(info.global);
    b.br_on_null(b2);
    b.br(b1);
    b.end();
    b.call(info.function);
    b.end();
  }

  void convertType(w.ValueType from, w.ValueType? to, CodeGenCallback code) {
    if (to != null) {
      translator.convertType(function, from, to, code);
    } else {
      code(function.body);
    }
  }

  void defaultConstant(Constant node) {
    throw "Unsupported constant: $node";
  }

  @override
  void visitNullConstant(NullConstant node) {
    w.ValueType? expectedType = this.expectedType;
    if (expectedType != constants.translator.voidMarker) {
      w.HeapType heapType =
          expectedType is w.RefType ? expectedType.heapType : w.HeapType.data;
      w.Instructions b = function.body;
      b.ref_null(heapType);
    }
  }

  @override
  void visitBoolConstant(BoolConstant constant) {
    convertType(w.NumType.i32, expectedType, (b) {
      b.i32_const(constant.value ? 1 : 0);
    });
  }

  @override
  void visitIntConstant(IntConstant constant) {
    convertType(w.NumType.i64, expectedType, (b) {
      b.i64_const(constant.value);
    });
  }

  @override
  void visitDoubleConstant(DoubleConstant constant) {
    convertType(w.NumType.f64, expectedType, (b) {
      b.f64_const(constant.value);
    });
  }

  @override
  void visitStringConstant(StringConstant constant) {
    // TODO: String contents
    ClassInfo info = translator.classInfo[translator.coreTypes.stringClass]!;
    w.Instructions b = function.body;
    b.i32_const(info.classId);
    b.global_get(info.rtt);
    b.struct_new_with_rtt(info.struct);
  }

  void visitInstanceConstant(InstanceConstant constant) {
    ClassInfo info = translator.classInfo[constant.classNode]!;
    w.RefType type = w.RefType.def(info.struct, nullable: false);
    instantiateLazyConstant(constant, type, (function) {
      int fieldCount = constant.fieldValues.length;
      assert(info.struct.fields.length == 1 + fieldCount);
      List<Constant?> subConstants = List.filled(1 + fieldCount, null);
      constant.fieldValues.forEach((reference, subConstant) {
        int fieldIndex = translator.fieldIndex[reference.asField]!;
        assert(subConstants[fieldIndex] == null);
        subConstants[fieldIndex] = subConstant;
      });

      w.Instructions b = function.body;
      b.i32_const(info.classId);
      for (int i = 1; i <= fieldCount; i++) {
        constants.instantiateConstant(
            function, subConstants[i]!, info.struct.fields[i].type.unpacked);
      }
      b.global_get(info.rtt);
      b.struct_new_with_rtt(info.struct);
    });
  }

  void visitListConstant(ListConstant constant) {
    // TODO: Use unmodifiable list
    ClassInfo info = translator.classInfo[translator.fixedLengthListClass]!;
    w.RefType type = w.RefType.def(info.struct, nullable: false);
    instantiateLazyConstant(constant, type, (function) {
      w.RefType refType = info.struct.fields.last.type.unpacked as w.RefType;
      w.ArrayType arrayType =
          (refType.heapType as w.DefHeapType).def as w.ArrayType;
      w.ValueType elementType = arrayType.elementType.type.unpacked;
      int length = constant.entries.length;
      w.Local arrayLocal = function.addLocal(
          refType.withNullability(!translator.options.localNullability));
      w.Instructions b = function.body;
      b.i32_const(info.classId);
      b.i64_const(length);
      b.i32_const(length);
      b.rtt_canon(arrayType);
      b.array_new_default_with_rtt(arrayType);
      b.local_set(arrayLocal);
      for (int i = 0; i < length; i++) {
        b.local_get(arrayLocal);
        b.i32_const(i);
        constants.instantiateConstant(
            function, constant.entries[i], elementType);
        b.array_set(arrayType);
      }
      b.local_get(arrayLocal);
      if (arrayLocal.type.nullable) {
        b.ref_as_non_null();
      }
      b.global_get(info.rtt);
      b.struct_new_with_rtt(info.struct);
    });
  }
}
