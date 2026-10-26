/// Observes reported handle equality without paths or exported pointers.
/// JNI handles can be recycled: equality does not prove Surface object identity,
/// a surface failure, or consumer intent.
class BtrSurfaceProbe {
  int _loads = 0;
  int _unloads = 0;
  int? _previousSurface;

  int? _surface(String Function(String) read) {
    try {
      final raw = read('wid');
      if (raw.isEmpty || raw.length > 20) return null;
      final value = int.tryParse(raw);
      return value != null && value >= 0 ? value : null;
    } catch (_) {
      return null;
    }
  }

  Map<String, Object> loaded(String Function(String) read) {
    final surface = _surface(read);
    final known = surface != null && surface > 0;
    final previous = _previousSurface;
    _previousSurface = known ? surface : null;
    return {
      'load': ++_loads,
      'unloads': _unloads,
      'widNonzero': known,
      if (known && previous != null)
        'widSameAsPreviousLoad': surface == previous,
    };
  }

  Map<String, Object> unloaded(String Function(String) read) {
    final surface = _surface(read);
    return {
      'load': _loads,
      'unloads': ++_unloads,
      'widKnown': surface != null,
      if (surface != null) 'widCleared': surface == 0,
    };
  }
}
