import 'dart:math' as math;

import '../otf/cff/char_string.dart';
import '../otf/cff/char_string_optimizer.dart';
import '../otf/table/glyph/flag.dart';
import '../otf/table/glyph/header.dart';
import '../otf/table/glyph/simple.dart';
import '../utils/misc.dart';
import '../utils/otf.dart';
import 'outline.dart';

class GenericGlyphMetrics {
  GenericGlyphMetrics(this.xMin, this.xMax, this.yMin, this.yMax);

  factory GenericGlyphMetrics.empty() => GenericGlyphMetrics(0,0,0,0);

  final int xMin;
  final int xMax;
  final int yMin;
  final int yMax;

  int get width => xMax - xMin;

  int get height => yMax - yMin;
}

/// Generic glyph. 
/// Used as an intermediate storage between different types of glyphs
/// (including OpenType's CharString, TrueType outlines).
class GenericGlyph {
  GenericGlyph(this.outlines);

  GenericGlyph.empty() : outlines = [];

  factory GenericGlyph.fromSimpleTrueTypeGlyph(SimpleGlyph glyph) {
    final isOnCurveList = glyph.flags.map((e) => e.onCurvePoint).toList();
    final endPoints = [-1, ...glyph.endPtsOfContours];
    
    final outlines = [
      for (var i = 1; i < endPoints.length; i++)
        Outline(
          glyph.pointList.sublist(endPoints[i - 1] + 1, endPoints[i] + 1),
          isOnCurveList.sublist(endPoints[i - 1] + 1, endPoints[i] + 1),
          true,
          true,
          FillRule.nonzero
        )
    ];

    return GenericGlyph(outlines);
  }

  final List<Outline> outlines;

  /// Deep copy of a glyph and its outlines
  GenericGlyph copy() {
    final outlines = this.outlines.map((e) => e.copy()).toList();
    return GenericGlyph(outlines);
  }

  List<bool> _getIsOnCurveList() {
    return [
      for (final o in outlines)
        ...o.isOnCurveList
    ];
  }

  List<math.Point> _getPointList() {
    return [
      for (final o in outlines)
        ...o.pointList
    ];
  }

  List<int> _getEndPoints() {
    final endPoints = [-1];

    for (final o in outlines) {
      endPoints.add(endPoints.last + o.pointList.length);
    }

    endPoints.removeAt(0);

    return endPoints;
  }

  List<CharStringCommand> toCharStringCommands() {
    for (final outline in outlines) {
      if (outline.hasQuadCurves) {
        // NOTE: what about doing it implicitly?
        throw UnsupportedError('CharString outlines must contain cubic curves');
      }
    }

    final commandList = <CharStringCommand>[];

    final isOnCurveList = _getIsOnCurveList();
    final endPoints = _getEndPoints();
    final pointList = _getPointList();

    final relX = absToRelCoordinates(pointList.map((e) => e.x.toInt()).toList());
    final relY = absToRelCoordinates(pointList.map((e) => e.y.toInt()).toList());

    bool isContourStart = true;

    for (int i = 0; i < relX.length; i++) {
      if (isContourStart) {
        commandList.add(CharStringCommand.moveto(relX[i], relY[i]));
        isContourStart = false;
        continue;
      }

      if (!isOnCurveList[i] && !isOnCurveList[i + 1]) {
        final points = [
          for (int p = 0; p < 3; p++)
            ...[relX[i + p], relY[i + p]]
        ];

        commandList.add(CharStringCommand.curveto(points));
        i += 2;
      } else {
        commandList.add(CharStringCommand.lineto(relX[i], relY[i]));
      }

      if (endPoints.isNotEmpty && endPoints.first == i) {
        endPoints.removeAt(0);
        isContourStart = true;
      }
    }

    return CharStringOptimizer.optimize(commandList);
  }

  SimpleGlyph toSimpleTrueTypeGlyph() {
    final isOnCurveList = _getIsOnCurveList();
    final endPoints = _getEndPoints();
    final pointList = _getPointList();

    final absXcoordinates = pointList.map((p) => p.x.toInt()).toList();
    final absYcoordinates = pointList.map((p) => p.y.toInt()).toList();

    final relXcoordinates = absToRelCoordinates(absXcoordinates);
    final relYcoordinates = absToRelCoordinates(absYcoordinates);

    final xMin = absXcoordinates.fold<int>(kInt32Max, math.min);
    final yMin = absYcoordinates.fold<int>(kInt32Max, math.min);
    final xMax = absXcoordinates.fold<int>(kInt32Min, math.max);
    final yMax = absYcoordinates.fold<int>(kInt32Min, math.max);

    final flags = [
      for (int i = 0; i < pointList.length; i++)
        SimpleGlyphFlag.createForPoint(relXcoordinates[i], relYcoordinates[i], isOnCurveList[i])
    ];

    // TODO: compact flags: repeat & not short same flag

    return SimpleGlyph(
      GlyphHeader(endPoints.length, xMin, yMin, xMax, yMax),
      endPoints,
      [],
      flags,
      pointList,
    );
  }

  GenericGlyph resize(int unitsPerEm, int ascender, int descender) {
    final metrics = this.metrics;
    final longestSide = math.max(metrics.height, metrics.width);
    final sideRatio = (ascender + descender) / longestSide;

    // No need to resize
    if ((sideRatio - 1).abs() < .02) {
      return this;
    }
    
    final newOutlines = outlines.map((o) {
      final newOutline = o.copy();
      final newPointList = newOutline.pointList.map(
        (e) => math.Point<num>(e.x, e.y) * sideRatio
      ).toList();
      newOutline.pointList..clear()..addAll(newPointList);
      return newOutline;
    }).toList();

    return GenericGlyph(newOutlines);
  }

  GenericGlyph center(int unitsPerEm, int ascender, int descender) {
    final metrics = this.metrics;
    
    final offsetX = -metrics.xMin;
    final offsetY = (ascender + descender) / 2 - metrics.height / 2 - metrics.yMin;
    
    final newOutlines = outlines.map((o) {
      final newOutline = o.copy();
      final newPointList = newOutline.pointList.map(
        (e) => math.Point<num>(e.x + offsetX, e.y + offsetY)
      ).toList();
      newOutline.pointList..clear()..addAll(newPointList);
      return newOutline;
    }).toList();

    return GenericGlyph(newOutlines);
  }

  GenericGlyphMetrics get metrics {
    final points = _getPointList();

    if (points.isEmpty) {
      return GenericGlyphMetrics.empty();
    }

    int xMin = kInt32Max, yMin = kInt32Max, xMax = kInt32Min, yMax = kInt32Min;
    
    for (final p in points) {
      xMin = math.min(xMin, p.x.toInt());
      xMax = math.max(xMax, p.x.toInt());
      yMin = math.min(yMin, p.y.toInt());
      yMax = math.max(yMax, p.y.toInt());
    }

    return GenericGlyphMetrics(xMin, xMax, yMin, yMax);
  }
}