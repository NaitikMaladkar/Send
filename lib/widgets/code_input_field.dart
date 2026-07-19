import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Six-column OTP-style code input. Each column accepts 1 digit. Auto-
/// advances on type, backspace navigates to previous. Calls [onChanged]
/// with the concatenated 6-digit string (or shorter while editing).
///
/// Used in:
///   - Add-friend screen (enter friend's current 6-digit code)
///   - Identity-display screen (read-only display of own current code)
class CodeInputField extends StatefulWidget {
  final ValueChanged<String> onChanged;
  final bool autofocus;
  final bool readOnly;
  final TextEditingController? controller;

  const CodeInputField({
    super.key,
    required this.onChanged,
    this.autofocus = false,
    this.readOnly = false,
    this.controller,
  });

  @override
  State<CodeInputField> createState() => _CodeInputFieldState();
}

class _CodeInputFieldState extends State<CodeInputField> {
  late final List<FocusNode> _focusNodes;
  late final List<TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    _focusNodes = List.generate(6, (_) => FocusNode());
    _controllers = List.generate(6, (_) => TextEditingController());
    if (widget.controller != null) {
      _syncFromExternal(widget.controller!.text);
      widget.controller!.addListener(() {
        _syncFromExternal(widget.controller!.text);
      });
    }
  }

  void _syncFromExternal(String value) {
    if (widget.controller == null) return;
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    for (int i = 0; i < 6; i++) {
      final ch = i < digits.length ? digits[i] : '';
      if (_controllers[i].text != ch) {
        _controllers[i].text = ch;
      }
    }
  }

  @override
  void dispose() {
    for (final fn in _focusNodes) {
      fn.dispose();
    }
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _emitChanged() {
    final s = _controllers.map((c) => c.text).join();
    widget.onChanged(s);
  }

  void _onChanged(int index, String value) {
    if (value.isEmpty) return;
    // Take only last char if user pasted multiple.
    final ch = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (ch.isEmpty) {
      _controllers[index].clear();
      _emitChanged();
      return;
    }
    final lastChar = ch.characters.last;
    _controllers[index].text = lastChar;
    if (index < 5) {
      _focusNodes[index + 1].requestFocus();
    } else {
      _focusNodes[index].unfocus();
    }
    _emitChanged();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: List.generate(6, (i) {
        return SizedBox(
          width: 44,
          height: 56,
          child: TextFormField(
            controller: _controllers[i],
            focusNode: _focusNodes[i],
            autofocus: widget.autofocus && i == 0,
            readOnly: widget.readOnly,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(1)],
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: scheme.onSurface),
            decoration: InputDecoration(
              contentPadding: EdgeInsets.zero,
              filled: true,
              fillColor: scheme.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: scheme.outline.withOpacity(0.4)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: scheme.outline.withOpacity(0.4)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: scheme.primary, width: 2),
              ),
            ),
            onChanged: (v) => _onChanged(i, v),
            onTap: () {
              // Select-all on tap for easy overwrite.
              _controllers[i].selection = TextSelection(baseOffset: 0, extentOffset: _controllers[i].text.length);
            },
          ),
        );
      }),
    );
  }
}
