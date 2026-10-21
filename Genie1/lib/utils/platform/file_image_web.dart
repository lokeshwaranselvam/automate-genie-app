import 'platform_file_web.dart';
import 'package:flutter/material.dart';

ImageProvider fileImage(File file) => MemoryImage(file.readAsBytesSync());
