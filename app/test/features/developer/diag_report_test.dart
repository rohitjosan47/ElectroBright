import 'package:electrobright/core/protocol/eb/eb_reply.dart';
import 'package:electrobright/features/developer/diag_report.dart';
import 'package:electrobright/features/developer/light_developer_screen.dart';
import 'package:electrobright/l10n/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';

/// DIAG made readable: the summary, the counters by group, restart reasons
/// in plain words and the text Copy puts on the clipboard.
void main() {
  const String line =
      'DIAG:rx=42,ovf=0,rej=0,sdrop=0,unk=1,err=2,coal=3,bin=900,binbad=0,'
      'gaps=4,nretry=0,edrop=0,nvsw=7,nvsf=0,frames=12000,overrun=5,'
      'rmaxus=812,heapmin=180000,stkc=3000,stkr=2000,rst=4,up=93784,slot=1,'
      'rb=1,pv=1,endms=842,newkey=9';

  DiagReport parse(String l) {
    final EbReply r = parseEbReply(l);
    expect(r, isA<EbDiag>());
    return DiagReport((r as EbDiag).values);
  }

  test('the summary: uptime, last restart, slot, rollback, check', () {
    final DiagReport d = parse(line);
    expect(d.uptime, const Duration(days: 1, hours: 2, minutes: 3, seconds: 4));
    expect(d.restart, RestartReason.crash);
    expect(d.slot, 1);
    expect(d.rolledBack, isTrue);
    expect(d.pendingVerify, isTrue);
    expect(d.raw, line);
    // Firmware before 3.8.2 sends no pv.
    expect(parse('DIAG:slot=0,rb=0').pendingVerify, isNull);
  });

  test('counters by group, in the light\'s order; unknown keys kept', () {
    final DiagReport d = parse(line);
    expect(d.counters(DiagGroup.render), <(String, int)>[
      ('frames', 12000),
      ('overrun', 5),
      ('rmaxus', 812),
    ]);
    expect(
      d.counters(DiagGroup.connection).map(((String, int) e) => e.$1),
      <String>[
        'rx',
        'ovf',
        'rej',
        'sdrop',
        'unk',
        'err',
        'coal',
        'bin',
        'binbad',
        'gaps',
        'nretry',
        'edrop',
      ],
    );
    expect(
      d.counters(DiagGroup.system).map(((String, int) e) => e.$1),
      <String>['nvsw', 'nvsf', 'heapmin', 'stkc', 'stkr', 'endms'],
    );
    expect(d.counters(DiagGroup.other), <(String, int)>[('newkey', 9)]);
  });

  test('firmware before 3.8.0: no slot or rollback', () {
    final DiagReport d = parse('DIAG:rx=1,rst=1,up=5');
    expect(d.slot, isNull);
    expect(d.rolledBack, isNull);
    expect(d.restart, RestartReason.powerOn);
    expect(parse('DIAG:rb=0').rolledBack, isFalse);
  });

  test('every ESP reset reason has plain words', () {
    final AppLocalizationsEn l = AppLocalizationsEn();
    expect(RestartReason.of(1), RestartReason.powerOn);
    expect(RestartReason.of(3), RestartReason.software);
    expect(RestartReason.of(6), RestartReason.taskWatchdog);
    expect(RestartReason.of(9), RestartReason.brownout);
    expect(RestartReason.of(15), RestartReason.cpuLockup);
    expect(RestartReason.of(16), RestartReason.unknown);
    expect(RestartReason.of(-1), RestartReason.unknown);
    final Set<String> words = <String>{
      for (final RestartReason r in RestartReason.values)
        restartReasonText(l, r),
    };
    expect(words, hasLength(RestartReason.values.length));
    expect(restartReasonText(l, RestartReason.brownout), contains('brownout'));
  });

  test('uptime in its two largest units', () {
    expect(formatUptime(const Duration(seconds: 12)), '12 s');
    expect(formatUptime(const Duration(minutes: 4, seconds: 2)), '4 min 2 s');
    expect(formatUptime(const Duration(hours: 2, minutes: 5)), '2 h 5 min');
    expect(
      formatUptime(const Duration(days: 3, hours: 4, minutes: 9)),
      '3 d 4 h',
    );
  });

  test('Copy: readable lines, then the reply as sent', () {
    final AppLocalizationsEn l = AppLocalizationsEn();
    final String text = diagText(
      l,
      parse(line),
      name: 'Desk',
      version: '3.8.0',
    );
    expect(text.split('\n').first, 'Desk · Firmware 3.8.0');
    expect(text, contains('Running for: 1 d 2 h'));
    expect(text, contains('Last restart: Crashed'));
    expect(
      text,
      contains('Rollback: An update was rolled back since the last install'),
    );
    expect(
      text,
      contains('Firmware check: Still checking itself (not confirmed yet)'),
    );
    expect(text, contains('  Lost colour frames: 4'));
    expect(text, contains('  newkey: 9'));
    expect(text.split('\n').last, line);
  });
}
