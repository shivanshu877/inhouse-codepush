import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Runs `tooling/push-branch.sh <branch>` for the dashboard's "build & push
/// from a branch" card, one build at a time, and keeps its output for polling.
///
/// Disabled (no branches, builds refused) unless both [scriptPath] and
/// [worktreeDir] are set — see `PUSH_BRANCH_SCRIPT` / `WORKTREE_DIR`.
class BranchBuilder {
  BranchBuilder({required this.scriptPath, required this.worktreeDir});

  final String scriptPath;
  final String worktreeDir;

  /// Enough of the tail of a Gradle/Flutter build to see why it failed.
  static const int maxLogChars = 200000;

  String? _branch;
  bool _running = false;
  int? _exitCode;
  DateTime? _startedAt;
  final StringBuffer _log = StringBuffer();

  bool get enabled => scriptPath.isNotEmpty && worktreeDir.isNotEmpty;

  /// Branch names as git allows them, minus anything the script could read as
  /// an option (`--current`, `-x`) or that walks paths.
  static bool isValidBranch(String branch) =>
      RegExp(r'^[A-Za-z0-9_@][A-Za-z0-9._/@-]*$').hasMatch(branch) &&
      !branch.contains('..') &&
      !branch.endsWith('/') &&
      !branch.endsWith('.lock');

  /// Remote branches of the worktree's `origin`, sorted. Empty when disabled
  /// or when git fails.
  Future<List<String>> branches() async {
    if (!enabled) return const [];
    final result = await Process.run(
      'git',
      ['ls-remote', '--heads', 'origin'],
      workingDirectory: worktreeDir,
    );
    if (result.exitCode != 0) return const [];
    const prefix = 'refs/heads/';
    return LineSplitter.split(result.stdout as String)
        .map((line) => line.split('\t'))
        .where((parts) => parts.length == 2 && parts[1].startsWith(prefix))
        .map((parts) => parts[1].substring(prefix.length))
        .toList()
      ..sort();
  }

  /// Starts a build of [branch]. Returns null when it started, otherwise the
  /// reason it didn't (see [BuildRefusal]).
  Future<BuildRefusal?> start(String branch) async {
    if (!enabled) return BuildRefusal.notConfigured;
    if (!isValidBranch(branch)) return BuildRefusal.invalidBranch;
    if (_running) return BuildRefusal.busy;

    _running = true;
    _branch = branch;
    _exitCode = null;
    _startedAt = DateTime.now().toUtc();
    _log.clear();

    final Process process;
    try {
      process = await Process.start(scriptPath, [branch]);
    } on ProcessException catch (e) {
      _append('could not start $scriptPath: ${e.message}\n');
      _exitCode = -1;
      _running = false;
      return null;
    }

    final stdoutDone = process.stdout.transform(utf8.decoder).forEach(_append);
    final stderrDone = process.stderr.transform(utf8.decoder).forEach(_append);
    unawaited(
      process.exitCode.then((code) async {
        await Future.wait([stdoutDone, stderrDone]);
        _exitCode = code;
        _running = false;
      }),
    );
    return null;
  }

  void _append(String chunk) {
    _log.write(chunk);
    if (_log.length > maxLogChars) {
      final tail = _log.toString().substring(_log.length - maxLogChars);
      _log
        ..clear()
        ..write(tail);
    }
  }

  /// Shape the dashboard polls: `running`, `branch`, `log`, `exit_code`.
  Map<String, dynamic> status() => {
        'enabled': enabled,
        'running': _running,
        'branch': _branch,
        'exit_code': _exitCode,
        'started_at': _startedAt?.toIso8601String(),
        'log': _log.toString(),
      };
}

enum BuildRefusal {
  notConfigured(HttpStatus.serviceUnavailable,
      'branch builds are off: set PUSH_BRANCH_SCRIPT and WORKTREE_DIR'),
  invalidBranch(HttpStatus.badRequest, 'invalid branch name'),
  busy(HttpStatus.conflict, 'a build is already running');

  const BuildRefusal(this.statusCode, this.message);

  final int statusCode;
  final String message;
}
