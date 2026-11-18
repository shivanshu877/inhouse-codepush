import 'dart:io';

import 'package:inhouse_codepush_server/src/build/branch_builder.dart';
import 'package:test/test.dart';

Future<void> _git(List<String> args, String dir) async {
  final r = await Process.run('git', args, workingDirectory: dir);
  if (r.exitCode != 0) throw StateError('git $args: ${r.stderr}');
}

Future<Map<String, dynamic>> _waitDone(BranchBuilder b) async {
  for (var i = 0; i < 100; i++) {
    final s = b.status();
    if (s['running'] == false) return s;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('build never finished');
}

void main() {
  test('disabled without script and worktree', () async {
    final b = BranchBuilder(scriptPath: '', worktreeDir: '');
    expect(b.enabled, isFalse);
    expect(await b.branches(), isEmpty);
    expect(await b.start('main'), BuildRefusal.notConfigured);
  });

  test('rejects names the script could read as options or paths', () {
    for (final ok in ['main', 'feature/x', '@develop', 'fix-1.2', 'a_b']) {
      expect(BranchBuilder.isValidBranch(ok), isTrue, reason: ok);
    }
    for (final bad in [
      '--current',
      '-x',
      'a..b',
      'a b',
      'a;rm',
      'x/',
      'x.lock',
      ''
    ]) {
      expect(BranchBuilder.isValidBranch(bad), isFalse, reason: bad);
    }
  });

  group('with a worktree and script', () {
    late Directory tmp;
    late String worktree;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('branch_builder_test');
      final origin = '${tmp.path}/origin.git';
      worktree = '${tmp.path}/wt';
      await _git(['init', '-q', '--bare', origin], tmp.path);
      await _git(['init', '-q', '-b', 'main', worktree], tmp.path);
      await _git([
        '-c',
        'user.name=t',
        '-c',
        'user.email=t@t',
        'commit',
        '-q',
        '--allow-empty',
        '-m',
        'init'
      ], worktree);
      await _git(['branch', 'feature/x'], worktree);
      await _git(['remote', 'add', 'origin', origin], worktree);
      await _git(['push', '-q', 'origin', 'main', 'feature/x'], worktree);
    });

    tearDown(() => tmp.delete(recursive: true));

    Future<String> script(String body) async {
      final f = File('${tmp.path}/push-branch.sh')
        ..writeAsStringSync('#!/bin/sh\n$body\n');
      await Process.run('chmod', ['+x', f.path]);
      return f.path;
    }

    test('lists origin branches, sorted', () async {
      final b = BranchBuilder(
          scriptPath: await script('exit 0'), worktreeDir: worktree);
      expect(await b.branches(), ['feature/x', 'main']);
    });

    test('runs the script with the branch and reports exit code and log',
        () async {
      final b = BranchBuilder(
        scriptPath: await script('echo "building \$1"; echo oops >&2; exit 3'),
        worktreeDir: worktree,
      );
      expect(await b.start('feature/x'), isNull);
      final s = await _waitDone(b);
      expect(s['branch'], 'feature/x');
      expect(s['exit_code'], 3);
      expect(s['log'], contains('building feature/x'));
      expect(s['log'], contains('oops'));
    });

    test('one build at a time', () async {
      final b = BranchBuilder(
          scriptPath: await script('sleep 1'), worktreeDir: worktree);
      expect(await b.start('main'), isNull);
      expect(await b.start('main'), BuildRefusal.busy);
      expect((await _waitDone(b))['exit_code'], 0);
      expect(await b.start('main'), isNull);
      await _waitDone(b);
    });
  });
}
