import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:health/health.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:excel/excel.dart';
import 'package:share_plus/share_plus.dart';

class SaveAsCSV extends StatefulWidget {
  @override
  _SaveAsCSVState createState() => _SaveAsCSVState();
}

enum AppState {
  DATA_NOT_FETCHED,
  FETCHING_DATA,
  DATA_READY,
  NO_DATA,
  AUTHORIZED,
  AUTH_NOT_GRANTED,
  DATA_ADDED,
  DATA_DELETED,
  DATA_NOT_ADDED,
  DATA_NOT_DELETED,
  STEPS_READY,
  HEALTH_CONNECT_STATUS,
}

class _SaveAsCSVState extends State<SaveAsCSV> {
  List<HealthDataPoint> _healthDataList = [];
  AppState _state = AppState.DATA_NOT_FETCHED;
  var _contentHealthConnectStatus;

  bool _isTripActive = false;
  List<Map<String, dynamic>> _tripData = [];
  Timer? _dataTimer;
  bool _isLoading = false;

  late DateTime startingTime;
  late DateTime endingTime;

  List<HealthDataType> get types => (Platform.isAndroid)
      ? dataTypesAndroid
      : (Platform.isIOS)
      ? dataTypesIOS
      : [];

  static final dataTypesAndroid = [
    HealthDataType.HEART_RATE,
  ];

  static final dataTypesIOS = [
    HealthDataType.HEART_RATE,
  ];

  List<HealthDataAccess> get permissions =>
      types.map((e) => HealthDataAccess.READ).toList();

  @override
  void initState() {
    Health().configure(useHealthConnectIfAvailable: true);
    super.initState();
  }

  Future<void> authorize() async {
    await Permission.activityRecognition.request();
    await Permission.location.request();

    bool? hasPermissions =
    await Health().hasPermissions(types, permissions: permissions);

    if (hasPermissions == null || !hasPermissions) {
      bool authorized = false;
      try {
        authorized = await Health()
            .requestAuthorization(types, permissions: permissions);
      } catch (error) {
        debugPrint("Exception in authorize: $error");
      }

      setState(() => _state =
      (authorized) ? AppState.AUTHORIZED : AppState.AUTH_NOT_GRANTED);
    } else {
      setState(() => _state = AppState.AUTHORIZED);
    }
  }

  Future<void> fetchHRData() async {
    final now = DateTime.now();
    final startTime = startingTime;

    print("INSIDE THE FETCHHRDATA FUNCTION");
    print("STARTING TIME: $startingTime");
    print("ENDING TIME: $endingTime");

    try {
      List<HealthDataPoint> healthData = await Health().getHealthDataFromTypes(
        types: types,
        startTime: startTime,
        endTime: now,
      );

      print("DATA FETCHED");
      print("HEALTH DATA: $healthData");

      if (healthData.isNotEmpty) {
        _healthDataList.addAll(healthData);
        _healthDataList = Health().removeDuplicates(_healthDataList);

        for (HealthDataPoint dataPoint in _healthDataList) {
          _tripData.add({
            'type': dataPoint.typeString,
            'timestamp': dataPoint.dateTo,
            'value': dataPoint.value
          });
        }

        print("DATA ADDED TO TRIP DATA");
      } else {
        print("No health data found for the given timeframe.");
      }
    } catch (e) {
      print("Error fetching health data: $e");
    }
  }

  void _toggleTrip() async {
    setState(() {
      _isTripActive = !_isTripActive;
      if (_isTripActive) {
        _isLoading = false; // Ensure loading indicator is off when trip starts
        startingTime = DateTime.now();
        _startCollectingData();
      } else {
        endingTime = DateTime.now();
        _stopCollectingData();
      }
    });

    if (!_isTripActive) {
      setState(() {
        _isLoading = true;
      });
      await fetchHRData();
      await _saveDataToExcel();
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _startCollectingData() {
    _dataTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      _collectSensorAndLocationData();
    });
  }

  void _stopCollectingData() {
    _dataTimer?.cancel();
  }

  void _collectSensorAndLocationData() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
    }

    Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);

    accelerometerEvents.listen((AccelerometerEvent event) {
      var sensorData = {
        'type': 'accelerometer',
        'x': event.x,
        'y': event.y,
        'z': event.z,
        'timestamp': DateTime.now(),
      };
      _tripData.add(sensorData);
    });

    gyroscopeEvents.listen((GyroscopeEvent event) {
      var sensorData = {
        'type': 'gyroscope',
        'x': event.x,
        'y': event.y,
        'z': event.z,
        'timestamp': DateTime.now(),
      };
      _tripData.add(sensorData);
    });

    magnetometerEvents.listen((MagnetometerEvent event) {
      var sensorData = {
        'type': 'magnetometer',
        'x': event.x,
        'y': event.y,
        'z': event.z,
        'timestamp': DateTime.now(),
      };
      _tripData.add(sensorData);
    });

    var locationData = {
      'type': 'location',
      'latitude': position.latitude,
      'longitude': position.longitude,
      'timestamp': DateTime.now(),
    };

    _tripData.add(locationData);
  }

  Future<void> _saveDataToExcel() async {
    var excel = Excel.createExcel();
    Sheet sheetObject = excel['Sheet1'];

    sheetObject.appendRow([
      TextCellValue('Timestamp'),
      TextCellValue('Latitude'),
      TextCellValue('Longitude'),
      TextCellValue('accelerometer_x'),
      TextCellValue('accelerometer_y'),
      TextCellValue('accelerometer_z'),
      TextCellValue('gyroscope_x'),
      TextCellValue('gyroscope_y'),
      TextCellValue('gyroscope_z'),
      TextCellValue('magnetometer_x'),
      TextCellValue('magnetometer_y'),
      TextCellValue('magnetometer_z'),
      TextCellValue('heart_beat'),
    ]);

    // Create a map to store data by timestamp (up to the minute)
    Map<String, Map<String, dynamic>> dataByTimestamp = {};

    // Process sensor data
    for (var data in _tripData) {
      String timestampKey = (data['timestamp'] as DateTime).toIso8601String().substring(0, 16); // Up to the minute
      if (!dataByTimestamp.containsKey(timestampKey)) {
        dataByTimestamp[timestampKey] = {
          'timestamp': data['timestamp'],
          'latitude': data['latitude'],
          'longitude': data['longitude'],
          'accelerometer_x': null,
          'accelerometer_y': null,
          'accelerometer_z': null,
          'gyroscope_x': null,
          'gyroscope_y': null,
          'gyroscope_z': null,
          'magnetometer_x': null,
          'magnetometer_y': null,
          'magnetometer_z': null,
          'heart_beat': null,
        };
      }

      switch (data['type']) {
        case 'accelerometer':
          dataByTimestamp[timestampKey]!['accelerometer_x'] = data['x'];
          dataByTimestamp[timestampKey]!['accelerometer_y'] = data['y'];
          dataByTimestamp[timestampKey]!['accelerometer_z'] = data['z'];
          break;
        case 'gyroscope':
          dataByTimestamp[timestampKey]!['gyroscope_x'] = data['x'];
          dataByTimestamp[timestampKey]!['gyroscope_y'] = data['y'];
          dataByTimestamp[timestampKey]!['gyroscope_z'] = data['z'];
          break;
        case 'magnetometer':
          dataByTimestamp[timestampKey]!['magnetometer_x'] = data['x'];
          dataByTimestamp[timestampKey]!['magnetometer_y'] = data['y'];
          dataByTimestamp[timestampKey]!['magnetometer_z'] = data['z'];
          break;
        case 'location':
          dataByTimestamp[timestampKey]!['latitude'] = data['latitude'];
          dataByTimestamp[timestampKey]!['longitude'] = data['longitude'];
          break;
      }
    }

    // Process heart rate data
    for (var data in _healthDataList) {
      String timestampKey = data.dateTo.toIso8601String().substring(0, 16); // Up to the minute
      if (dataByTimestamp.containsKey(timestampKey)) {
        dataByTimestamp[timestampKey]!['heart_beat'] = data.value;
      }
    }

    // Append rows to the sheet
    for (var key in dataByTimestamp.keys) {
      var rowData = dataByTimestamp[key];
      sheetObject.appendRow([
        TextCellValue(rowData!['timestamp'].toString()),
        TextCellValue(rowData['latitude']?.toString() ?? ''),
        TextCellValue(rowData['longitude']?.toString() ?? ''),
        TextCellValue(rowData['accelerometer_x']?.toString() ?? ''),
        TextCellValue(rowData['accelerometer_y']?.toString() ?? ''),
        TextCellValue(rowData['accelerometer_z']?.toString() ?? ''),
        TextCellValue(rowData['gyroscope_x']?.toString() ?? ''),
        TextCellValue(rowData['gyroscope_y']?.toString() ?? ''),
        TextCellValue(rowData['gyroscope_z']?.toString() ?? ''),
        TextCellValue(rowData['magnetometer_x']?.toString() ?? ''),
        TextCellValue(rowData['magnetometer_y']?.toString() ?? ''),
        TextCellValue(rowData['magnetometer_z']?.toString() ?? ''),
        TextCellValue(rowData['heart_beat']?.toString() ?? ''),
      ]);
    }

    var directory = await getApplicationDocumentsDirectory();
    var filePath = "${directory.path}/trip_data.xlsx";
    var fileBytes = excel.encode();
    File(filePath)
      ..createSync(recursive: true)
      ..writeAsBytesSync(fileBytes!);

    final box = context.findRenderObject() as RenderBox?;
    await Share.shareXFiles([XFile(filePath)], text: 'Trip Data Excel File', sharePositionOrigin: box!.localToGlobal(Offset.zero) & box.size);

    setState(() {
      _tripData.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Save as CSV'),
      ),
      body: Center(
        child: _isLoading
            ? CircularProgressIndicator()
            : Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            ElevatedButton(
              onPressed: authorize,
              child: Text('Authorize Health Data'),
            ),
            ElevatedButton(
              onPressed: _toggleTrip,
              child: Text(_isTripActive ? 'Stop Trip' : 'Start Trip'),
            ),
          ],
        ),
      ),
    );
  }
}
