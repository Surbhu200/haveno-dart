/*
 * Copyright Haveno
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import 'package:haveno_dart/haveno_dart.dart';
import 'package:test/test.dart';

void main() {
  group('HavenoClient', () {
    test('stores the url of the Haveno daemon', () {
      final client = HavenoClient('http://localhost:8079', 'testpass');
      expect(client.getUrl(), 'http://localhost:8079');
    });

    test('throws HavenoError when constructed with an empty url', () {
      expect(() => HavenoClient('', 'testpass'), throwsA(isA<HavenoError>()));
    });
  });

  group('HavenoUtils', () {
    test('xmrToAtomicUnits converts 1.5 XMR to atomic units', () {
      expect(HavenoUtils.xmrToAtomicUnits('1.5'), BigInt.from(1500000000000));
    });
  });
}
