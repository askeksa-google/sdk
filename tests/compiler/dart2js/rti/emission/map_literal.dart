// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart = 2.7

/*spec:nnbd-off.class: global#Map:instance*/

/*class: global#LinkedHashMap:*/
/*class: global#JsLinkedHashMap:checks=[],instance*/

/*spec:nnbd-off.class: global#double:checkedInstance,checks=[],instance,typeArgument*/

/*class: global#JSDouble:checks=[],instance*/

main() {
  <int, double>{}[0] = 0.5;
}
