// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@pragma("wasm:entry-point")
class _BoxedBool implements bool {
  // A boxed bool contains an unboxed bool.
  @pragma("wasm:entry-point")
  bool value = false;

  bool operator &(bool other) => this & other;
  bool operator ^(bool other) => this ^ other;
  bool operator |(bool other) => this | other;
}
