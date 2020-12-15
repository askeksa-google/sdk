// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/analyzer.dart';
import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/code_generator.dart';
import 'package:dart2wasm/functions.dart';
import 'package:dart2wasm/intrinsics.dart';

import 'package:kernel/ast.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/type_environment.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class Translator {
  Component component;
  List<Library> libraries;
  CoreTypes coreTypes;
  TypeEnvironment typeEnvironment;

  late Intrinsics intrinsics;

  Map<Class, ClassInfo> classes = {};
  Map<Field, int> fieldIndex = {};
  Map<Member, w.BaseFunction> functions = {};
  late Procedure mainFunction;
  late w.Module m;

  Translator(this.component, this.coreTypes, this.typeEnvironment)
      : libraries = [component.libraries.first] {
    intrinsics = Intrinsics(this);
  }

  w.Module translate() {
    m = w.Module();

    ClassInfoCollector(this).collect();

    w.FunctionType printType = m.addFunctionType([w.NumType.i64], []);
    w.ImportedFunction printFun = m.importFunction("console", "log", printType);
    for (Procedure printMember in component.libraries
        .firstWhere((l) => l.name == "dart.core")
        .procedures
        .where((p) => p.name.name == "print")) {
      functions[printMember] = printFun;
    }

    FunctionCollector(this).collect();

    mainFunction =
        libraries.first.procedures.firstWhere((p) => p.name.name == "main");
    w.DefinedFunction mainFun = functions[mainFunction] as w.DefinedFunction;
    m.exportFunction("main", mainFun);

    Analyzer(this).visitComponent(component);
    var codeGen = CodeGenerator(this);
    for (Member member in functions.keys) {
      w.BaseFunction function = functions[member]!;
      if (function is w.DefinedFunction) {
        print(member);
        print(member.function.body);
        codeGen.generate(member, function);
      }
    }

    return m;
  }

  w.ValueType translateType(DartType type) {
    assert(type is! VoidType);
    if (type is InterfaceType) {
      if (type.classNode == coreTypes.intClass) {
        if (type.isPotentiallyNullable) {
          throw "Nullable int not supported";
        }
        return w.NumType.i64;
      }
      if (type.classNode == coreTypes.doubleClass) {
        if (type.isPotentiallyNullable) {
          throw "Nullable double not supported";
        }
        return w.NumType.f64;
      }
      if (type.classNode == coreTypes.boolClass) {
        if (type.isPotentiallyNullable) {
          throw "Nullable bool not supported";
        }
        return w.NumType.i32;
      }
      return classes[type.classNode]!.repr;
    }
    if (type is FunctionType) {
      // TODO
      return w.RefType.any();
    }
    throw "Unsupported type ${type.runtimeType}";
  }
}
