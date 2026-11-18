import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:inhouse_codepush_server/src/build/branch_builder.dart';

/// `POST /admin/build {"branch": "..."}` starts `push-branch.sh <branch>`;
/// `GET /admin/build` returns its status and log for the dashboard to poll.
Future<Response> onRequest(RequestContext context) async {
  final builder = context.read<BranchBuilder>();
  switch (context.request.method) {
    case HttpMethod.get:
      return Response.json(body: builder.status());
    case HttpMethod.post:
      final Object? body;
      try {
        body = await context.request.json();
      } catch (_) {
        return Response.json(
          statusCode: HttpStatus.badRequest,
          body: {'error': 'invalid json'},
        );
      }
      final branch = body is Map<String, dynamic> ? body['branch'] : null;
      if (branch is! String || branch.isEmpty) {
        return Response.json(
          statusCode: HttpStatus.badRequest,
          body: {'error': 'branch required'},
        );
      }
      final refusal = await builder.start(branch);
      if (refusal != null) {
        return Response.json(
          statusCode: refusal.statusCode,
          body: {'error': refusal.message},
        );
      }
      return Response.json(
        statusCode: HttpStatus.accepted,
        body: {'started': true, 'branch': branch},
      );
    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}
