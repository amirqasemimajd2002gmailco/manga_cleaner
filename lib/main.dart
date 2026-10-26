import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MangaCleanerApp());
}

class MangaCleanerApp extends StatelessWidget {
  const MangaCleanerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Manga Cleaner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const CleanerHomePage(),
    );
  }
}

class CleanerHomePage extends StatefulWidget {
  const CleanerHomePage({super.key});

  @override
  State<CleanerHomePage> createState() => _CleanerHomePageState();
}

class _CleanerHomePageState extends State<CleanerHomePage> {
  img.Image? _image; // editable pixels
  ui.Image? _uiImage; // for rendering
  Uint8List? _bytes; // original loaded bytes (optional)
  String? _fileName;

  // Color used for fill (default: white)
  img.ColorUint8 _fillColor = img.ColorUint8.rgba(255, 255, 255, 255);

  // Flood fill similarity threshold (0..255). Higher => more tolerant.
  int _threshold = 35;

  // For mapping widget coords to image coords:
  final GlobalKey _imageKey = GlobalKey();

  Future<void> _openImage() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg'],
      withData: true,
    );

    if (res == null || res.files.isEmpty) return;
    final file = res.files.first;
    final data = file.bytes;
    if (data == null) return;

    final decoded = img.decodeImage(data);
    if (decoded == null) {
      _showSnack('Cannot decode image.');
      return;
    }

    // Ensure RGBA 8-bit
    final rgba = decoded.convert(numChannels: 4);

    setState(() {
      _bytes = data;
      _fileName = file.name;
      _image = rgba;
    });

    await _rebuildUiImage();
  }

  Future<void> _saveAs() async {
    if (_image == null) return;

    final out = img.encodePng(_image!);
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save cleaned image',
      fileName: _suggestOutName(_fileName),
      type: FileType.custom,
      allowedExtensions: const ['png'],
    );
    if (path == null) return;

    final bytes = Uint8List.fromList(out);
    await FilePicker.platform.writeFile(path: path, bytes: bytes);

    _showSnack('Saved: $path');
  }

  String _suggestOutName(String? name) {
    if (name == null || name.trim().isEmpty) return 'cleaned.png';
    final n = name;
    final dot = n.lastIndexOf('.');
    final base = dot > 0 ? n.substring(0, dot) : n;
    return '${base}_cleaned.png';
    // always saving as png for lossless
  }

  Future<void> _rebuildUiImage() async {
    final im = _image;
    if (im == null) return;

    final rgbaBytes = Uint8List.fromList(img.encodePng(im));
    final codec = await ui.instantiateImageCodec(rgbaBytes);
    final frame = await codec.getNextFrame();

    setState(() => _uiImage = frame.image);
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  /// Convert local pointer position (inside RawImage widget) to image pixel coords.
  /// Returns null if out of bounds or image not loaded.
  img.Point<int>? _toImagePixel(Offset localPos) {
    final uiIm = _uiImage;
    final im = _image;
    final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (uiIm == null || im == null || box == null) return null;

    final w = box.size.width;
    final h = box.size.height;
    if (w <= 0 || h <= 0) return null;

    // We render with BoxFit.contain. Need compute fitted rect.
    final imgW = uiIm.width.toDouble();
    final imgH = uiIm.height.toDouble();

    final scale = math.min(w / imgW, h / imgH);
    final drawW = imgW * scale;
    final drawH = imgH * scale;
    final dx = (w - drawW) / 2;
    final dy = (h - drawH) / 2;

    final xIn = localPos.dx - dx;
    final yIn = localPos.dy - dy;

    if (xIn < 0 || yIn < 0 || xIn >= drawW || yIn >= drawH) return null;

    final px = (xIn / scale).floor().clamp(0, im.width - 1);
    final py = (yIn / scale).floor().clamp(0, im.height - 1);
    return img.Point<int>(px, py);
  }

  void _pickColorAt(img.Point<int> p) {
    final im = _image!;
    final c = im.getPixel(p.x, p.y);
    setState(() {
      _fillColor = img.ColorUint8.rgba(c.r.toInt(), c.g.toInt(), c.b.toInt(), 255);
    });
  }

  Future<void> _fillAt(img.Point<int> p) async {
    final im = _image!;
    _floodFill(im, p.x, p.y, _fillColor, _threshold);
    await _rebuildUiImage();
  }

  /// Simple BFS flood fill with threshold (color distance).
  /// Fills connected pixels similar to the start pixel.
  void _floodFill(img.Image im, int sx, int sy, img.ColorUint8 fill, int threshold) {
    final start = im.getPixel(sx, sy);
    final sr = start.r.toInt();
    final sg = start.g.toInt();
    final sb = start.b.toInt();

    // If start already close to fill, still ok, but avoid infinite work
    // We'll just proceed; it's safe.

    final w = im.width;
    final h = im.height;

    final visited = Uint8List(w * h); // 0/1
    int idx(int x, int y) => y * w + x;

    bool similar(img.Pixel px) {
      final dr = (px.r.toInt() - sr).abs();
      final dg = (px.g.toInt() - sg).abs();
      final db = (px.b.toInt() - sb).abs();
      // max-channel distance
      return math.max(dr, math.max(dg, db)) <= threshold;
    }

    final qx = <int>[];
    final qy = <int>[];
    qx.add(sx);
    qy.add(sy);
    visited[idx(sx, sy)] = 1;

    while (qx.isNotEmpty) {
      final x = qx.removeLast();
      final y = qy.removeLast();

      final px = im.getPixel(x, y);
      if (!similar(px)) continue;

      im.setPixelRgba(x, y, fill.r, fill.g, fill.b, 255);

      // 4-neighborhood
      if (x > 0) {
        final i = idx(x - 1, y);
        if (visited[i] == 0) {
          visited[i] = 1;
          qx.add(x - 1);
          qy.add(y);
        }
      }
      if (x < w - 1) {
        final i = idx(x + 1, y);
        if (visited[i] == 0) {
          visited[i] = 1;
          qx.add(x + 1);
          qy.add(y);
        }
      }
      if (y > 0) {
        final i = idx(x, y - 1);
        if (visited[i] == 0) {
          visited[i] = 1;
          qx.add(x);
          qy.add(y - 1);
        }
      }
      if (y < h - 1) {
        final i = idx(x, y + 1);
        if (visited[i] == 0) {
          visited[i] = 1;
          qx.add(x);
          qy.add(y + 1);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final uiIm = _uiImage;

    final fillColor = Color.fromARGB(255, _fillColor.r, _fillColor.g, _fillColor.b);

    return Scaffold(
      appBar: AppBar(
        title: Text(_fileName == null ? 'Manga Cleaner (Windows)' : 'Manga Cleaner — $_fileName'),
        actions: [
          IconButton(
            tooltip: 'Open image',
            onPressed: _openImage,
            icon: const Icon(Icons.folder_open),
          ),
          IconButton(
            tooltip: 'Save as PNG',
            onPressed: _image == null ? null : _saveAs,
            icon: const Icon(Icons.save),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Toolbar
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: [
                const Text('Fill color:'),
                const SizedBox(width: 8),
                Container(width: 22, height: 22, decoration: BoxDecoration(color: fillColor, border: Border.all(color: Colors.black26))),
                const SizedBox(width: 14),
                const Text('Threshold:'),
                Expanded(
                  child: Slider(
                    value: _threshold.toDouble(),
                    min: 0,
                    max: 80,
                    divisions: 80,
                    label: _threshold.toString(),
                    onChanged: (v) => setState(() => _threshold = v.round()),
                  ),
                ),
                const SizedBox(width: 8),
                Text(_threshold.toString()),
              ],
            ),
          ),

          const Divider(height: 1),

          // Image area
          Expanded(
            child: Center(
              child: Container(
                color: Colors.black12,
                padding: const EdgeInsets.all(8),
                child: AspectRatio(
                  aspectRatio: uiIm == null ? 16 / 9 : (uiIm.width / uiIm.height),
                  child: Listener(
                    onPointerDown: (event) async {
                      if (_image == null || _uiImage == null) return;

                      final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
                      if (box == null) return;

                      final local = box.globalToLocal(event.position);
                      final p = _toImagePixel(local);
                      if (p == null) return;

                      // Left click => fill
                      if (event.buttons == kPrimaryMouseButton) {
                        await _fillAt(p);
                      }
                      // Right click => pick color
                      else if (event.buttons == kSecondaryMouseButton) {
                        _pickColorAt(p);
                      }
                    },
                    child: Container(
                      key: _imageKey,
                      alignment: Alignment.center,
                      color: Colors.black12,
                      child: uiIm == null
                          ? const Text('Open an image (PNG/JPG) to start.\n\nLeft click: fill\nRight click: pick color', textAlign: TextAlign.center)
                          : FittedBox(
                              fit: BoxFit.contain,
                              child: RawImage(image: uiIm),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'Left click: Flood fill (clean bubble)  |  Right click: Pick color',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
