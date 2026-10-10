import 'dart:io';

/// The caller must supply an exact path it created for its own recording.
Future<void> removeTemporaryRecording(String path) async {
  final file = File(path);
  if (await file.exists()) await file.delete();
}
