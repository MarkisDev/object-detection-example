import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();

  runApp(const MyApp());
}

late List<CameraDescription> cameras;
String? labelString;
String? confidenceString;

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        title: 'Flutter Demo',
        theme: ThemeData(
          primarySwatch: Colors.blue,
        ),
        home: MyHomePage());
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  CameraImage? img;
  dynamic controller;
  dynamic objectDetector;
  bool isBusy = false;
  dynamic _detectedObjects;
  List<Widget> stackChildren = [];
  @override
  void initState() {
    super.initState();
    initModel();
    initCamera();
  }

  initModel() async {
    final modelPath = await _getModel('assets/ml/model.tflite');

    final options = LocalObjectDetectorOptions(
        modelPath: modelPath,
        classifyObjects: true,
        multipleObjects: true,
        mode: DetectionMode.stream,
        confidenceThreshold: 0.5);
    objectDetector = ObjectDetector(options: options);
  }

  initCamera() async {
    controller = CameraController(cameras[0], ResolutionPreset.high);
    await controller.initialize().then((_) async {
      await startStream();
      if (!mounted) {
        return;
      }
    }).catchError((Object e) {
      if (e is CameraException) {
        switch (e.code) {
          case 'CameraAccessDenied':
            print('Camera access denied!');
            break;
          default:
            print('Camera initalization error!');
            break;
        }
      }
    });
  }

  Future<String> _getModel(String assetPath) async {
    if (Platform.isAndroid) {
      return 'flutter_assets/$assetPath';
    }
    final path = '${(await getApplicationSupportDirectory()).path}/$assetPath';
    await Directory(dirname(path)).create(recursive: true);
    final file = File(path);
    if (!await file.exists()) {
      final byteData = await rootBundle.load(assetPath);
      await file.writeAsBytes(byteData.buffer
          .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));
    }
    return file.path;
  }

  startStream() async {
    await controller.startImageStream((image) async {
      if (!isBusy) {
        isBusy = true;
        img = image;
        await performDetectionOnFrame();
      }
    });
  }

  performDetectionOnFrame() async {
    InputImage frameImg = getInputImage();
    List<DetectedObject> objects = await objectDetector.processImage(frameImg);
    double zoomLevel = await controller.getMaxZoomLevel();
    setState(() {
      _detectedObjects = objects;
    });
    isBusy = false;
  }

  InputImage getInputImage() {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in img!.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();
    final Size imageSize = Size(img!.width.toDouble(), img!.height.toDouble());
    final camera = cameras[0];

    final planeData = img!.planes.map(
      (Plane plane) {
        return InputImagePlaneMetadata(
          bytesPerRow: plane.bytesPerRow,
          height: plane.height,
          width: plane.width,
        );
      },
    ).toList();

    final inputImageData = InputImageData(
      size: imageSize,
      imageRotation:
          InputImageRotationValue.fromRawValue(camera.sensorOrientation)!,
      inputImageFormat: InputImageFormatValue.fromRawValue(img!.format.raw)!,
      planeData: planeData,
    );

    final inputImage =
        InputImage.fromBytes(bytes: bytes, inputImageData: inputImageData);

    return inputImage;
  }

  Widget drawRectangleOverObjects() {
    if (_detectedObjects == null ||
        controller == null ||
        !controller.value.isInitialized) {
      return Container(
          child: Center(
        child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Text('Loading...'),
              CircularProgressIndicator(),
            ]),
      ));
    }

    final Size imageSize = Size(
      controller.value.previewSize!.height,
      controller.value.previewSize!.width,
    );
    CustomPainter painter = ObjectPainter(imageSize, _detectedObjects);
    return CustomPaint(
      painter: painter,
    );
  }

  @override
  Widget build(BuildContext context) {
    Size size = MediaQuery.of(context).size;
    // ToastContext().init(context);
    if (controller != null) {
      // stackChildren.add(Positioned(top: 0.0, left: 0.0, child: Text(text)));
      stackChildren.add(
        Positioned(
          top: 0.0,
          left: 0.0,
          width: size.width,
          height: size.height,
          child: Container(
            child: (controller.value.isInitialized)
                ? AspectRatio(
                    aspectRatio: controller.value.aspectRatio,
                    child: CameraPreview(controller),
                  )
                : Container(),
          ),
        ),
      );
      stackChildren.add(
        Positioned(
            top: 0.0,
            left: 0.0,
            width: size.width,
            height: size.height,
            child: drawRectangleOverObjects()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text("Object detector"),
        backgroundColor: Color.fromARGB(255, 126, 0, 252),
      ),
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(
            child: Container(
                margin: const EdgeInsets.only(top: 0),
                color: Colors.black,
                child: Stack(
                  children: stackChildren,
                )),
          ),
          Container(
              color: Colors.white,
              height: MediaQuery.of(context).size.width * 0.30,
              width: MediaQuery.of(context).size.width,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Name: $labelString',
                      style: const TextStyle(fontSize: 21)),
                  Text('Confidence: $confidenceString',
                      style: const TextStyle(fontSize: 21))
                ],
              )),
        ],
      ),
    );
  }
}

class ObjectPainter extends CustomPainter {
  ObjectPainter(this.imgSize, this.objects);

  final Size imgSize;
  final List<DetectedObject> objects;

  @override
  void paint(Canvas canvas, Size size) {
    // Using TouchyCanvas to enable interactivity
    // Calculating the scale factor to resize the rectangle (newSize/originalSize)
    final double scaleX = size.width / imgSize.width;
    final double scaleY = size.height / imgSize.height;

    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10.0
      ..color = Color.fromARGB(255, 255, 0, 0);

    for (DetectedObject detectedObject in objects) {
      canvas.drawRect(
        Rect.fromLTRB(
          detectedObject.boundingBox.left * scaleX,
          detectedObject.boundingBox.top * scaleY,
          detectedObject.boundingBox.right * scaleX,
          detectedObject.boundingBox.bottom * scaleY,
        ),
        paint,
      );

      var list = detectedObject.labels;
      for (Label label in list) {
        labelString = label.text;
        confidenceString = label.confidence.toStringAsFixed(2);
      }
    }
  }

  @override
  bool shouldRepaint(ObjectPainter oldDelegate) {
    // Repaint if object is moving or new objects detected
    return oldDelegate.imgSize != imgSize || oldDelegate.objects != objects;
  }
}
