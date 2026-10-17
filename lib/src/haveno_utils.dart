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

import 'dart:async';
import 'dart:io';

import 'package:decimal/decimal.dart';

import 'generated/pb.pb.dart';

/// Collection of utilities for working with Haveno.
class HavenoUtils {
  static int logLevel = 0;
  static const List<String> months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static int lastLogTimeMs = 0;
  static final BigInt AU_PER_XMR = BigInt.from(1000000000000);

  /// Set the log level with 0 being least verbose.
  static void setLogLevel(int level) {
    if (level < 0) throw ArgumentError('Log level must be an integer >= 0');
    logLevel = level;
  }

  /// Get the log level.
  static int getLogLevel() => logLevel;

  /// Log a message.
  static void log(int level, String msg) {
    if (level < 0) throw ArgumentError('Log level must be an integer >= 0');
    if (logLevel >= level) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final since = lastLogTimeMs != 0 ? ' (+${now - lastLogTimeMs} ms)' : '\t';
      lastLogTimeMs = now;
      // ignore: avoid_print
      print('${formatTimestamp(now)}$since\t[L$level] $msg');
    }
  }

  /// Format a timestamp as e.g. Jul-07 hh:mm:ss:ms.
  static String formatTimestamp(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    String pad(int n, int width) => n.toString().padLeft(width, '0');
    return '${months[date.month - 1]}-${date.day} ${pad(date.hour, 2)}:${pad(date.minute, 2)}:${pad(date.second, 2)}:${pad(date.millisecond, 3)}';
  }

  /// Kill the given process (and its children on Windows).
  static Future<void> kill(Process process, [ProcessSignal? signal]) async {
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/PID', process.pid.toString(), '/T', '/F']);
    } else {
      process.kill(signal ?? ProcessSignal.sigint);
    }
  }

  /// Wait for the duration.
  static Future<void> waitFor(int durationMs) => Future<void>.delayed(Duration(milliseconds: durationMs));

  /// Convert XMR to atomic units.
  static BigInt xmrToAtomicUnits(Object amountXmr) {
    final scaled = Decimal.parse(amountXmr.toString()) * Decimal.parse(AU_PER_XMR.toString());
    return scaled.round().toBigInt();
  }

  /// Convert atomic units to XMR.
  static double atomicUnitsToXmr(Object amountAtomicUnits) {
    return (Decimal.parse(amountAtomicUnits.toString()) / Decimal.parse(AU_PER_XMR.toString())).toDouble();
  }

  /// Divide one atomic units by another.
  static double divide(BigInt au1, BigInt au2) {
    return (Decimal.parse(au1.toString()) / Decimal.parse(au2.toString())).toDouble();
  }

  /// Multiply a bigint by a number or bigint.
  static BigInt multiply(BigInt a, Object b) {
    final product = Decimal.parse(a.toString()) * Decimal.parse(b.toString());
    return product.round().toBigInt();
  }

  /// Calculate the difference from a first bigint to a second, as a percentage (float).
  static double percentageDiff(BigInt a, BigInt b) {
    return divide(a - b, a);
  }

  /// Return the absolute value of the given bigint.
  static BigInt abs(BigInt a) => a < BigInt.zero ? -a : a;

  /// Return the maximum of two bigints.
  static BigInt max(BigInt bi1, BigInt bi2) => bi1 > bi2 ? bi1 : bi2;

  // ------------------------- PAYMENT ACCOUNT FORMS --------------------------

  /// Get a validated payment method id from a string or form id.
  static String getPaymentMethodId(Object id) {
    if (id is String) {
      final upper = id.toUpperCase();
      if (!PaymentAccountForm_FormId.values.any((v) => v.name == upper)) {
        throw ArgumentError('Invalid payment method: $upper');
      }
      return upper;
    }
    if (id is PaymentAccountForm_FormId) return id.name;
    throw ArgumentError('Unsupported payment method id: $id');
  }

  /// Stringify a payment account form.
  static String formToString(PaymentAccountForm form) {
    var str = '';
    for (final field in form.fields) {
      str += '${field.id.name}: ${getFormValue(form, field.id)}\n';
    }
    return str.trim();
  }

  /// Determine if a form has a field.
  static bool hasFormField(PaymentAccountForm form, PaymentAccountFormField_FieldId fieldId) {
    for (final field in form.fields) {
      if (field.id == fieldId) return true;
    }
    return false;
  }

  /// Get a form field value.
  static String getFormValue(PaymentAccountForm form, PaymentAccountFormField_FieldId fieldId) {
    for (final field in form.fields) {
      if (field.id == fieldId) return field.value;
    }
    throw ArgumentError('PaymentAccountForm does not have field ${fieldId.name}');
  }

  /// Set a form field value.
  static void setFormValue(PaymentAccountForm form, PaymentAccountFormField_FieldId fieldId, String value) {
    for (final field in form.fields) {
      if (field.id == fieldId) {
        field.value = value;
        return;
      }
    }
    throw ArgumentError('PaymentAccountForm does not have field ${fieldId.name}');
  }
}
