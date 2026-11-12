// Stand-alone copy of tool/send_announcements.dart for GitHub Actions: needs only Dart, no Flutter and no app code.
// Sends the push for every document in `announcements` that has no `pushedAt`, then writes `pushedAt`.
//
//   SHIKHAR_SERVICE_ACCOUNT=<key.json> dart run send.dart [--dry-run | --check]
//
// Keep the topic names in step with lib/domain/announcement.dart (`announcements`, `announcements_class_<n>`).

import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart' as auth;

const maxPushAge = Duration(hours: 48);

Future<void> main(List<String> args) async {
  final path = Platform.environment['SHIKHAR_SERVICE_ACCOUNT'];
  if (path == null || !File(path).existsSync()) {
    stderr.writeln('Set SHIKHAR_SERVICE_ACCOUNT to the path of the service-account JSON key.');
    exit(2);
  }
  final key = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final project = key['project_id'] as String;
  final client = await auth.clientViaServiceAccount(
    auth.ServiceAccountCredentials.fromJson(key),
    ['https://www.googleapis.com/auth/datastore', 'https://www.googleapis.com/auth/firebase.messaging'],
  );
  final dryRun = args.contains('--dry-run');

  Future<void> push(String topic, String title, String body, Map<String, String> data, {bool validateOnly = false}) async {
    final r = await client.post(
      Uri.parse('https://fcm.googleapis.com/v1/projects/$project/messages:send'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        if (validateOnly) 'validate_only': true,
        'message': {
          'topic': topic,
          'notification': {'title': title, 'body': body},
          'data': data,
        },
      }),
    );
    if (r.statusCode != 200) throw StateError('FCM ${r.statusCode} ${r.body}');
  }

  try {
    if (args.contains('--check')) {
      await push('announcements', 'Check', 'Check', {'type': 'announcement'}, validateOnly: true);
      stdout.writeln('OK: this key may send pushes (nothing was delivered).');
      return;
    }

    final base = 'https://firestore.googleapis.com/v1/projects/$project/databases/(default)/documents/announcements';
    final listed = await client.get(Uri.parse('$base?pageSize=100'));
    if (listed.statusCode != 200) throw StateError('Firestore ${listed.statusCode} ${listed.body}');
    final docs = (jsonDecode(listed.body)['documents'] as List?) ?? const [];
    final now = DateTime.now().toUtc();
    var sent = 0, old = 0, failed = 0;

    for (final raw in docs) {
      final doc = raw as Map<String, dynamic>;
      final id = (doc['name'] as String).split('/').last;
      final f = (doc['fields'] as Map<String, dynamic>?) ?? const {};
      if (f['pushedAt'] != null) continue;
      final title = f['title']?['stringValue'] as String?;
      final body = f['body']?['stringValue'] as String?;
      final created = DateTime.tryParse(f['createdAt']?['timestampValue'] as String? ?? '');
      if (title == null || title.trim().isEmpty || body == null || created == null) continue;
      final classes = [
        for (final v in (f['classes']?['arrayValue']?['values'] as List?) ?? const [])
          if (int.tryParse((v as Map)['integerValue']?.toString() ?? '') case final n?) n,
      ];
      final topics = classes.isEmpty ? ['announcements'] : [for (final c in classes) 'announcements_class_$c'];

      Future<void> markDone() async {
        final r = await client.patch(
          Uri.parse('$base/$id?updateMask.fieldPaths=pushedAt&currentDocument.exists=true'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'fields': {'pushedAt': {'timestampValue': now.toIso8601String()}}}),
        );
        if (r.statusCode != 200) throw StateError('Marking $id failed: ${r.statusCode} ${r.body}');
      }

      if (now.difference(created.toUtc()) > maxPushAge) {
        stdout.writeln('Not pushing "$title" ($id): older than ${maxPushAge.inHours} hours.');
        if (!dryRun) await markDone();
        old++;
        continue;
      }
      stdout.writeln('${dryRun ? 'Would send' : 'Sending'} "$title" to ${topics.join(', ')}.');
      if (dryRun) continue;
      var ok = true;
      for (final t in topics) {
        try {
          await push(t, title, body.length <= 180 ? body : '${body.substring(0, 177)}...', {'type': 'announcement', 'id': id});
        } catch (e) {
          ok = false;
          stderr.writeln('  Push to $t failed: $e');
        }
      }
      if (ok) {
        await markDone();
        sent++;
      } else {
        failed++;
      }
    }
    stdout.writeln('Done. Pushed $sent, skipped $old old, $failed failed (will be retried).');
    if (failed > 0) exitCode = 1;
  } finally {
    client.close();
  }
}
