// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@pragma("wasm:entry-point")
class _Function extends Function {
  // TODO: Make non-nullable
  @pragma("wasm:entry-point")
  WasmDataRef context;

  _Function._(this.context);
}
