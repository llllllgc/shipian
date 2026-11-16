import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unicode;
import 'atomic_commit.dart';
import 'integrity.dart';
import 'matcher.dart';
import 'models.dart';

enum ImageFormat { jpg, png }

class ConversionSource {
  const ConversionSource(this.file, this.root, {this.expectedHash});
  final PhotoFile file;
  final String root;
  final String? expectedHash;
}

class ConversionRequest {
  const ConversionRequest({
    required this.outputRoot,
    this.inputRoot,
    this.sources,
    this.format = ImageFormat.jpg,
    this.quality = 90,
  });
  final String outputRoot;
  final String? inputRoot;
  final List<ConversionSource>? sources;
  final ImageFormat format;
  final int quality;
}

class ConversionResult {
  const ConversionResult({
    required this.directory,
    required this.converted,
    required this.reused,
    required this.failures,
    required this.cancelled,
    required this.total,
  });
  final String directory;
  final List<String> converted, reused;
  final Map<String, String> failures;
  final bool cancelled;
  final int total;
  int get completed => converted.length + reused.length;
}

abstract class RawDecoder {
  Future<void> decode({
    required String input,
    required String output,
    required ImageFormat format,
    required int quality,
    required CancellationToken token,
  });
}

class NativeRawDecoder implements RawDecoder {
  NativeRawDecoder({String? executable})
    : executable = executable ?? _bundledExecutable();
  final String executable;
  static String _bundledExecutable() => Platform.isMacOS
      ? p.normalize(
          p.join(
            p.dirname(Platform.resolvedExecutable),
            '..',
            'Helpers',
            'shipian_raw_converter',
          ),
        )
      : p.join(
          p.dirname(Platform.resolvedExecutable),
          'shipian_raw_converter.exe',
        );

  @override
  Future<void> decode({
    required String input,
    required String output,
    required ImageFormat format,
    required int quality,
    required CancellationToken token,
  }) async {
    token.check();
    if (!await File(executable).exists()) {
      throw const FormatException('转换引擎缺失，请使用完整的软件包');
    }
    final process = await Process.start(executable, [
      input,
      output,
      format.name,
      '$quality',
    ]);
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final timer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (token.cancelled) process.kill(ProcessSignal.sigkill);
    });
    try {
      final exitCode = await process.exitCode.timeout(
        const Duration(minutes: 10),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          throw const FormatException('单张转换超时，请检查 RAW 文件');
        },
      );
      final outputText = await stdout;
      final errorText = await stderr;
      token.check();
      if (exitCode != 0) {
        final detail = errorText.trim();
        throw FormatException(
          '无法解码此 RAW${detail.isEmpty ? '' : '：${detail.length > 500 ? detail.substring(0, 500) : detail}'}',
        );
      }
      final info = jsonDecode(outputText) as Map<String, dynamic>;
      if ((info['width'] as int) <= 0 || (info['height'] as int) <= 0) {
        throw const FormatException('转换结果尺寸无效');
      }
    } finally {
      timer.cancel();
      process.kill(ProcessSignal.sigkill);
    }
  }
}

class RawImageConverter {
  RawImageConverter({RawDecoder? decoder})
    : decoder = decoder ?? NativeRawDecoder();
  final RawDecoder decoder;

  Future<ConversionResult> convert({
    required ConversionRequest request,
    required CancellationToken token,
    void Function(CopyProgress)? onProgress,
  }) async {
    if (request.quality < 1 || request.quality > 100) {
      throw const FormatException('JPG 画质必须在 1–100 之间');
    }
    final outputRoot = await canonicalDirectory(request.outputRoot);
    final quality = request.format == ImageFormat.png ? 100 : request.quality;
    var sources = request.sources;
    if (sources == null) {
      if (request.inputRoot == null) throw const FormatException('请选择 RAW 文件夹');
      final inputRoot = await canonicalDirectory(request.inputRoot!);
      sources = [
        for (final file in await PhotoMatcher().scanRaw(inputRoot, token))
          ConversionSource(file, inputRoot),
      ];
    }
    if (sources.isEmpty) throw const FormatException('没有可转换的 RAW');
    final directory = await _directory(
      outputRoot,
      p.join(
        'RAW转图片',
        request.format == ImageFormat.jpg ? 'JPG_${request.quality}' : 'PNG',
      ),
    );
    final log = File(p.join(directory, '.拾片转换记录.jsonl'));
    if (await FileSystemEntity.type(log.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('转换记录不能是符号链接');
    }
    // Hold an OS lock for the entire batch, including reads and crash recovery.
    // The lock file is stable; never unlink it while another process may wait.
    final lockFile = File(p.join(directory, '.拾片转换锁'));
    if (await FileSystemEntity.type(lockFile.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('转换锁不能是符号链接');
    }
    final lock = await lockFile.open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } catch (_) {
      await lock.close();
      throw const FormatException('这个目录正在转换，请稍后重试');
    }
    final converted = <String>[], reused = <String>[];
    final failures = <String, String>{};
    var cancelled = false, processed = 0;
    try {
      final records = <String, Map<String, dynamic>>{};
      if (await log.exists()) {
        final bytes = await log.readAsBytes();
        if (bytes.isNotEmpty && bytes.last != 10) {
          final writer = await log.open(mode: FileMode.append);
          try {
            await writer.truncate(bytes.lastIndexOf(10) + 1);
            await writer.flush();
          } finally {
            await writer.close();
          }
        }
        final lines = await log.readAsLines();
        for (final line in lines.where((line) => line.trim().isNotEmpty)) {
          final record = jsonDecode(line) as Map<String, dynamic>;
          if (record['event'] == 'verified') {
            records[record['destination'] as String] = record;
          } else if (record['event'] == 'prepare') {
            await _clearTemporary(directory, record['temporary'] as String);
          }
        }
      }
      final names = <String, int>{};
      for (final source in sources) {
        final key = _key(p.withoutExtension(source.file.relativePath));
        names[key] = (names[key] ?? 0) + 1;
      }
      for (final source in sources) {
        String? temporary;
        final relative = source.file.relativePath;
        try {
          token.check();
          onProgress?.call(
            CopyProgress(
              completed: processed,
              total: sources.length,
              bytes: processed,
              totalBytes: sources.length,
              file: relative,
            ),
          );
          if (p.isAbsolute(relative) ||
              p.split(relative).contains('..') ||
              relative == '.' ||
              !p.equals(p.join(source.root, relative), source.file.path)) {
            throw const FormatException('RAW 相对路径无效');
          }
          await checkSnapshot(source.file, source.root);
          final sourceHash = await hashFile(File(source.file.path), token);
          if (source.expectedHash != null &&
              sourceHash != source.expectedHash) {
            throw const FormatException('归档 RAW 校验失败');
          }
          final stem = p.withoutExtension(relative);
          final collision = (names[_key(stem)] ?? 0) > 1;
          final destinationRelative =
              '${collision ? relative : stem}.${request.format.name}';
          final parent = await _directory(
            directory,
            p.dirname(destinationRelative),
          );
          final target = File(p.join(parent, p.basename(destinationRelative)));
          final previous = records[destinationRelative];
          if (await FileSystemEntity.type(target.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            if (previous == null ||
                previous['sourceHash'] != sourceHash ||
                previous['format'] != request.format.name ||
                previous['quality'] != quality ||
                await FileSystemEntity.type(target.path, followLinks: false) !=
                    FileSystemEntityType.file ||
                await hashFile(target, token) != previous['outputHash']) {
              throw const FormatException('同名文件已存在，已跳过');
            }
            await checkSnapshot(source.file, source.root);
            reused.add(destinationRelative);
          } else {
            final temp = await Directory(
              directory,
            ).createTemp('.shipian-convert-');
            temporary = p.basename(temp.path);
            await _append(log, {'event': 'prepare', 'temporary': temporary});
            final staged = File(p.join(temp.path, 'image.partial'));
            await decoder.decode(
              input: source.file.path,
              output: staged.path,
              format: request.format,
              quality: quality,
              token: token,
            );
            token.check();
            await _checkEncoded(staged, request.format);
            await checkSnapshot(source.file, source.root);
            if (await hashFile(File(source.file.path), token) != sourceHash) {
              throw const FormatException('转换期间 RAW 发生变化');
            }
            final receipt = <String, Object>{
              'event': 'verified',
              'source': source.file.path,
              'sourceHash': sourceHash,
              'destination': destinationRelative,
              'format': request.format.name,
              'quality': quality,
              'outputHash': await hashFile(staged, token),
            };
            token.check();
            await _append(log, receipt);
            commitWithoutReplacing(staged.path, target.path);
            converted.add(destinationRelative);
            records[destinationRelative] = receipt;
          }
        } on TaskCancelled {
          cancelled = true;
          break;
        } catch (error) {
          failures[relative] = error is FormatException
              ? error.message
              : error.toString();
        } finally {
          if (temporary != null) await _clearTemporary(directory, temporary);
        }
        processed++;
        onProgress?.call(
          CopyProgress(
            completed: processed,
            total: sources.length,
            bytes: processed,
            totalBytes: sources.length,
            file: relative,
          ),
        );
      }
    } finally {
      await lock.unlock();
      await lock.close();
    }
    return ConversionResult(
      directory: directory,
      converted: converted,
      reused: reused,
      failures: failures,
      cancelled: cancelled,
      total: sources.length,
    );
  }

  static String _key(String value) => unicode.nfc(value).toLowerCase();
  static Future<void> _append(File file, Map<String, Object> entry) =>
      file.writeAsString(
        '${jsonEncode(entry)}\n',
        mode: FileMode.append,
        flush: true,
      );

  static Future<String> _directory(String root, String relative) async {
    if (p.isAbsolute(relative) || p.split(relative).contains('..')) {
      throw const FormatException('输出相对路径无效');
    }
    var current = root;
    for (final part in p.split(relative)) {
      if (part == '.') continue;
      current = p.join(current, part);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await Directory(current).create();
      }
      if (await FileSystemEntity.type(current, followLinks: false) !=
              FileSystemEntityType.directory ||
          !p.equals(await Directory(current).resolveSymbolicLinks(), current)) {
        throw FileSystemException('输出路径被占用或包含符号链接', current);
      }
    }
    return current;
  }

  static Future<void> _clearTemporary(String root, String name) async {
    if (!RegExp(r'^\.shipian-convert-[a-zA-Z0-9_-]+$').hasMatch(name)) {
      throw const FormatException('临时文件记录无效');
    }
    final directory = Directory(p.join(root, name));
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    final file = File(p.join(directory.path, 'image.partial'));
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.file) {
      await file.delete();
    }
    if (await directory.list(followLinks: false).isEmpty) {
      await directory.delete();
    }
  }

  static Future<void> _checkEncoded(File file, ImageFormat format) async {
    final reader = await file.open();
    try {
      final head = await reader.read(8);
      final length = await reader.length();
      if (length < 16) throw const FormatException('转换结果不完整');
      await reader.setPosition(length - 2);
      final tail = await reader.read(2);
      final valid = format == ImageFormat.png
          ? head.join(',') == '137,80,78,71,13,10,26,10'
          : head[0] == 255 &&
                head[1] == 216 &&
                tail[0] == 255 &&
                tail[1] == 217;
      if (!valid) throw const FormatException('转换结果格式无效');
    } finally {
      await reader.close();
    }
  }
}
