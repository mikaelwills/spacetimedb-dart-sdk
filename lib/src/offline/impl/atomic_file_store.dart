import 'dart:io';

import '../../utils/sdk_logger.dart';

class AtomicFileStore {
  final String basePath;

  AtomicFileStore(this.basePath);

  Future<void> atomicWrite(File file, String content) async {
    final tempFile = File('${file.path}.tmp');
    final backupFile = File('${file.path}.bak');

    await file.parent.create(recursive: true);
    await tempFile.writeAsString(content, flush: true);

    if (await file.exists()) {
      try {
        await file.copy(backupFile.path);
      } catch (_) {}
    }

    await tempFile.rename(file.path);
  }

  Future<String?> readWithFallback(File file) async {
    if (await file.exists()) {
      try {
        return await file.readAsString();
      } catch (e) {
        SdkLogger.e('Failed to read ${file.path}: $e');
      }
    }

    final backupFile = File('${file.path}.bak');
    if (await backupFile.exists()) {
      try {
        SdkLogger.i('Recovering from backup: ${backupFile.path}');
        return await backupFile.readAsString();
      } catch (e) {
        SdkLogger.e('Failed to read backup ${backupFile.path}: $e');
      }
    }

    return null;
  }

  Future<void> recoverFromTempFiles(Directory directory) async {
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.tmp')) {
        final originalPath = entity.path.substring(0, entity.path.length - 4);
        final originalFile = File(originalPath);
        if (!await originalFile.exists()) {
          try {
            await entity.rename(originalPath);
          } catch (e) {
            SdkLogger.e('Failed to recover temp file: $e');
          }
        } else {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }
  }

  Future<void> cleanupBackup(File file) async {
    final backupFile = File('${file.path}.bak');
    if (await backupFile.exists()) {
      try {
        await backupFile.delete();
      } catch (_) {}
    }
  }
}
