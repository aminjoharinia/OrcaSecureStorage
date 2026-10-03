import 'dart:convert';
import 'dart:math';

/// Deterministic, realistic-looking general-ledger data: a chart of accounts
/// plus balanced journal entries, each stored under its own key
/// (`je_000001`, ...) the way an app would keep records in a key-value box.
class AccountingDataset {
  AccountingDataset._(this.entries, this.jsonBytes);

  /// Key -> value, ready to write into a container.
  final Map<String, dynamic> entries;

  /// Size of `json.encode(entries)` in UTF-8 bytes (the plaintext size).
  final int jsonBytes;

  int get journalEntryCount => entries.length - 2;

  /// Builds entries until the encoded container reaches [targetBytes].
  static AccountingDataset generate(int targetBytes, {int seed = 42}) {
    final rnd = Random(seed);
    final entries = <String, dynamic>{
      'chart_of_accounts': [
        for (final a in _accounts)
          {'code': a.$1, 'name': a.$2, 'type': a.$3, 'active': true},
      ],
      'company': {
        'name': 'Example Trading Pty Ltd',
        'baseCurrency': 'AUD',
        'fiscalYearStart': '2025-07-01',
        'taxRegistration': 'ABN 00 000 000 000',
      },
    };
    var size = utf8.encode(json.encode(entries)).length;
    var n = 0;
    while (size < targetBytes) {
      n++;
      final key = 'je_${n.toString().padLeft(6, '0')}';
      final entry = _journalEntry(n, rnd);
      entries[key] = entry;
      // "key":value, plus the comma.
      size += utf8.encode(json.encode(entry)).length + key.length + 4;
    }
    return AccountingDataset._(entries, utf8.encode(json.encode(entries)).length);
  }

  static Map<String, dynamic> _journalEntry(int n, Random rnd) {
    final journal = _journals[rnd.nextInt(_journals.length)];
    final date = DateTime.utc(2025, 7, 1).add(Duration(days: rnd.nextInt(365)));
    final currency = _currencies[rnd.nextInt(_currencies.length)];
    final lineCount = 2 + rnd.nextInt(5);
    final lines = <Map<String, dynamic>>[];
    var debitTotal = 0;
    for (var i = 0; i < lineCount - 1; i++) {
      final cents = 1000 + rnd.nextInt(5000000);
      debitTotal += cents;
      lines.add(_line(i + 1, cents, 0, rnd));
    }
    // One balancing credit line so every entry sums to zero.
    lines.add(_line(lineCount, 0, debitTotal, rnd));

    return {
      'id': 'JE-${n.toString().padLeft(6, '0')}',
      'journal': journal,
      'date': date.toIso8601String().substring(0, 10),
      'period': '${date.year}-${date.month.toString().padLeft(2, '0')}',
      'reference': '${journal.substring(0, 3).toUpperCase()}-${100000 + rnd.nextInt(899999)}',
      'description': _descriptions[rnd.nextInt(_descriptions.length)],
      'currency': currency,
      'exchangeRate': currency == 'AUD' ? 1.0 : (0.5 + rnd.nextInt(10000) / 10000),
      'lines': lines,
      'totalDebit': debitTotal / 100,
      'totalCredit': debitTotal / 100,
      'status': _statuses[rnd.nextInt(_statuses.length)],
      'createdBy': _users[rnd.nextInt(_users.length)],
      'createdAt': date.add(Duration(seconds: rnd.nextInt(86400))).toIso8601String(),
      'approvedBy': rnd.nextBool() ? _users[rnd.nextInt(_users.length)] : null,
      'attachments': rnd.nextInt(4),
      'reconciled': rnd.nextBool(),
    };
  }

  static Map<String, dynamic> _line(int no, int debit, int credit, Random rnd) {
    final account = _accounts[rnd.nextInt(_accounts.length)];
    return {
      'line': no,
      'accountCode': account.$1,
      'accountName': account.$2,
      'debit': debit / 100,
      'credit': credit / 100,
      'taxCode': _taxCodes[rnd.nextInt(_taxCodes.length)],
      'costCenter': 'CC-${100 + rnd.nextInt(20)}',
      'project': rnd.nextInt(3) == 0 ? 'PRJ-${1000 + rnd.nextInt(50)}' : null,
      'memo': _memos[rnd.nextInt(_memos.length)],
    };
  }

  static const _journals = ['Sales', 'Purchases', 'Payroll', 'Bank', 'General', 'Inventory'];
  static const _currencies = ['AUD', 'AUD', 'AUD', 'USD', 'EUR', 'NZD'];
  static const _statuses = ['draft', 'posted', 'posted', 'posted', 'reversed'];
  static const _taxCodes = ['GST', 'GST-FREE', 'INPUT', 'N-T', 'EXP'];
  static const _users = ['a.nguyen', 'j.smith', 'm.rossi', 's.khan', 'l.chen'];
  static const _descriptions = [
    'Monthly office rent',
    'Customer invoice – consulting services',
    'Supplier bill – raw materials',
    'Payroll run fortnightly',
    'Bank fees and charges',
    'Depreciation of equipment',
    'Accrued utilities expense',
    'Inventory stock adjustment',
    'Customer payment received',
    'Credit card statement reconciliation',
  ];
  static const _memos = [
    'Per contract terms',
    'Approved by finance',
    'Recurring monthly',
    'See attached receipt',
    'Quarter-end adjustment',
    '',
  ];
  static const _accounts = [
    ('1000', 'Cash at Bank', 'asset'),
    ('1010', 'Petty Cash', 'asset'),
    ('1100', 'Accounts Receivable', 'asset'),
    ('1200', 'Inventory', 'asset'),
    ('1300', 'Prepaid Expenses', 'asset'),
    ('1500', 'Office Equipment', 'asset'),
    ('1510', 'Accumulated Depreciation', 'asset'),
    ('2000', 'Accounts Payable', 'liability'),
    ('2100', 'GST Collected', 'liability'),
    ('2110', 'GST Paid', 'liability'),
    ('2200', 'PAYG Withholding', 'liability'),
    ('2300', 'Superannuation Payable', 'liability'),
    ('2500', 'Loan Payable', 'liability'),
    ('3000', 'Owner Equity', 'equity'),
    ('3100', 'Retained Earnings', 'equity'),
    ('4000', 'Sales Revenue', 'revenue'),
    ('4100', 'Consulting Revenue', 'revenue'),
    ('4200', 'Interest Income', 'revenue'),
    ('5000', 'Cost of Goods Sold', 'expense'),
    ('6000', 'Wages and Salaries', 'expense'),
    ('6100', 'Rent Expense', 'expense'),
    ('6200', 'Utilities', 'expense'),
    ('6300', 'Bank Fees', 'expense'),
    ('6400', 'Depreciation Expense', 'expense'),
    ('6500', 'Travel', 'expense'),
    ('6600', 'Software Subscriptions', 'expense'),
  ];
}
