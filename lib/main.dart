import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const GameCleanerApp());

// ─────────────────────────── Theme & constants ───────────────────────────

const Color kBg = Color(0xFF121212);
const Color kSurface = Color(0xFF1E1E1E);
const Color kCyan = Color(0xFF00E5FF);
const Color kGreen = Color(0xFF00E676);
const Color kDanger = Color(0xFFFF5252);

const int kMB = 1024 * 1024;
const int kGB = 1024 * kMB;

// ───────────────────────────── Formatting ────────────────────────────────

String formatBytes(int b) => b >= kGB
    ? '${(b / kGB).toStringAsFixed(2)} GB'
    : '${(b / kMB).toStringAsFixed(1)} MB';

String formatMB(int b) => (b / kMB).toStringAsFixed(2);

String formatDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

// ─────────────────────────────── Model ───────────────────────────────────

enum FileKind { apk, large }

class ScannedFile {
  const ScannedFile({
    required this.file,
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modified,
    required this.kind,
  });

  final File file;
  final String name;
  final String path;
  final int sizeBytes;
  final DateTime modified;
  final FileKind kind;

  String get sizeLabel => formatBytes(sizeBytes);
  String get dateLabel => formatDate(modified);
}

// ─────────────────────────────── Services ────────────────────────────────

class PermissionService {
  Future<int> _sdk() async =>
      (await DeviceInfoPlugin().androidInfo).version.sdkInt;

  /// Android 11+ (API 30+) needs "All files access" to read other apps'
  /// files in Download. Older versions use the classic storage permission.
  Future<bool> isGranted() async {
    final sdk = await _sdk();
    return sdk >= 30
        ? Permission.manageExternalStorage.isGranted
        : Permission.storage.isGranted;
  }

  Future<PermissionStatus> request() async {
    final sdk = await _sdk();
    return sdk >= 30
        ? Permission.manageExternalStorage.request()
        : Permission.storage.request();
  }
}

class StorageScanner {
  static const String publicDownloads = '/storage/emulated/0/Download';
  static const int largeThreshold = 50 * kMB;

  Future<Directory?> _root() async {
    final dir = Directory(publicDownloads);
    if (await dir.exists()) return dir;
    return getExternalStorageDirectory(); // fallback: app-specific dir
  }

  Future<List<ScannedFile>> scan() async {
    final root = await _root();
    if (root == null) return [];

    final results = <ScannedFile>[];
    final stream =
        root.list(recursive: true, followLinks: false).handleError((_) {});

    await for (final entity in stream) {
      if (entity is! File) continue;
      try {
        final isApk = entity.path.toLowerCase().endsWith('.apk');
        final stat = await entity.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        if (!isApk && stat.size <= largeThreshold) continue;

        results.add(ScannedFile(
          file: entity,
          name: entity.path.split('/').last,
          path: entity.path,
          sizeBytes: stat.size,
          modified: stat.modified,
          kind: isApk ? FileKind.apk : FileKind.large,
        ));
      } on FileSystemException {
        continue; // unreadable file: skip it
      }
    }

    results.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    return results;
  }
}

// ──────────────────────────────── App ────────────────────────────────────

class GameCleanerApp extends StatelessWidget {
  const GameCleanerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GameCleaner Utility',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(
          primary: kCyan,
          secondary: kGreen,
          surface: kSurface,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: kBg,
          foregroundColor: kCyan,
          centerTitle: true,
          elevation: 0,
        ),
      ),
      home: const CleanerPage(),
    );
  }
}

class CleanerPage extends StatefulWidget {
  const CleanerPage({super.key});

  @override
  State<CleanerPage> createState() => _CleanerPageState();
}

class _CleanerPageState extends State<CleanerPage> with WidgetsBindingObserver {
  final _permissions = PermissionService();
  final _scanner = StorageScanner();

  List<ScannedFile> _files = [];
  final Set<String> _selected = {};

  bool _loading = false;
  bool _deleting = false;
  bool _granted = false;
  bool _permanentlyDenied = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Re-check permission when returning from the system settings screen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_granted && !_loading) {
      _start(request: false);
    }
  }

  // ───────────────────────────── Logic ─────────────────────────────

  int get _totalBytes => _files.fold(0, (s, f) => s + f.sizeBytes);

  List<ScannedFile> get _selectedFiles =>
      _files.where((f) => _selected.contains(f.path)).toList();

  int get _selectedBytes =>
      _selectedFiles.fold(0, (s, f) => s + f.sizeBytes);

  Future<void> _start({bool request = true}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var granted = await _permissions.isGranted();
      if (!granted && request) {
        final status = await _permissions.request();
        granted = status.isGranted;
        _permanentlyDenied = status.isPermanentlyDenied;
      }
      if (!mounted) return;
      if (!granted) {
        setState(() {
          _granted = false;
          _loading = false;
        });
        return;
      }
      await _scan();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Something went wrong: $e';
        _loading = false;
      });
    }
  }

  Future<void> _scan() async {
    setState(() {
      _granted = true;
      _loading = true;
      _error = null;
    });
    try {
      final result = await _scanner.scan();
      if (!mounted) return;
      setState(() {
        _files = result;
        _selected.clear();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Scan failed: $e';
        _loading = false;
      });
    }
  }

  void _toggle(String path) {
    setState(() {
      if (!_selected.remove(path)) _selected.add(path);
    });
  }

  Future<void> _confirmDelete() async {
    final targets = _selectedFiles;
    if (targets.isEmpty) return;
    final bytes = targets.fold<int>(0, (s, f) => s + f.sizeBytes);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('Confirm deletion'),
        content: Text(
          'Are you sure you want to permanently delete '
          '${targets.length} files to free ${formatMB(bytes)} MB?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: kDanger)),
          ),
        ],
      ),
    );

    if (ok == true) await _delete(targets);
  }

  Future<void> _delete(List<ScannedFile> targets) async {
    setState(() => _deleting = true);

    final deleted = <String>{};
    var freedBytes = 0;
    var failed = 0;

    for (final t in targets) {
      try {
        await t.file.delete();
        deleted.add(t.path);
        freedBytes += t.sizeBytes;
      } on FileSystemException {
        failed++;
      }
    }

    if (!mounted) return;
    setState(() {
      _files.removeWhere((f) => deleted.contains(f.path));
      _selected.removeAll(deleted);
      _deleting = false;
    });

    final msg = failed == 0
        ? 'Freed ${formatMB(freedBytes)} MB (${deleted.length} files deleted).'
        : 'Freed ${formatMB(freedBytes)} MB. $failed file(s) could not be deleted.';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ─────────────────────────────── UI ───────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'GameCleaner Utility',
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1),
        ),
        actions: [
          IconButton(
            tooltip: 'Rescan',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: (_loading || _deleting) ? null : _start,
          ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: _granted ? _buildActionBar() : null,
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: kCyan));
    }
    if (_error != null) {
      return _message(Icons.error_outline_rounded, _error!, kDanger,
          button: 'Try again', onPressed: _start);
    }
    if (!_granted) {
      return _message(
        Icons.lock_outline_rounded,
        'To find large files and leftover APKs, GameCleaner needs '
        '"All files access". Files are only scanned on your device and '
        'are never uploaded.',
        kCyan,
        button: _permanentlyDenied ? 'Open settings' : 'Grant access',
        onPressed: _permanentlyDenied ? openAppSettings : _start,
      );
    }
    if (_files.isEmpty) {
      return _message(Icons.check_circle_outline_rounded,
          'Nothing to clean. No large files or APKs in Downloads.', kGreen);
    }
    return Column(
      children: [
        _buildDashboard(),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 12),
            itemCount: _files.length,
            itemBuilder: (_, i) => _buildTile(_files[i]),
          ),
        ),
      ],
    );
  }

  Widget _message(IconData icon, String text, Color color,
      {String? button, VoidCallback? onPressed}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: color),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center),
            if (button != null) ...[
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: kCyan,
                  foregroundColor: Colors.black,
                ),
                onPressed: onPressed,
                child: Text(button),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDashboard() {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kCyan, width: 1.2),
      ),
      child: Row(
        children: [
          _stat('Total space', formatBytes(_totalBytes), kCyan),
          Container(width: 1, height: 44, color: Colors.white12),
          _stat('Items found', '${_files.length}', kGreen),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, Color color) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 26, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white60)),
        ],
      ),
    );
  }

  Widget _buildTile(ScannedFile f) {
    final selected = _selected.contains(f.path);
    final isApk = f.kind == FileKind.apk;
    final accent = isApk ? kGreen : kCyan;

    return Card(
      color: kSurface,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: selected ? accent : Colors.transparent),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _toggle(f.path),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
          child: Row(
            children: [
              Checkbox(
                value: selected,
                activeColor: accent,
                checkColor: Colors.black,
                onChanged: (_) => _toggle(f.path),
              ),
              Icon(
                isApk
                    ? Icons.android_rounded
                    : Icons.insert_drive_file_rounded,
                color: accent,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      f.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      f.dateLabel,
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white54),
                    ),
                    Text(
                      f.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.white38),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                f.sizeLabel,
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15, color: accent),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionBar() {
    final enabled = _selected.isNotEmpty && !_deleting;
    return Container(
      color: kSurface,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton.icon(
            onPressed: enabled ? _confirmDelete : null,
            icon: _deleting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.black),
                  )
                : const Icon(Icons.delete_forever_rounded),
            label: Text(
              'Delete Selected (${formatMB(_selectedBytes)} MB)',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: kGreen,
              foregroundColor: Colors.black,
              disabledBackgroundColor: const Color(0xFF2A2A2A),
              disabledForegroundColor: Colors.white38,
            ),
          ),
        ),
      ),
    );
  }
}
