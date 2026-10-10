import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../utils/api/expense_claim_api.dart';
import '../utils/widget/home_back_button.dart';

const _expenseBlue = Color(0xFF1768C4);
const _expenseInk = Color(0xFF26313F);
const _expenseBorder = Color(0xFFD9DEE5);

class ExpenseClaimPage extends StatefulWidget {
  const ExpenseClaimPage({super.key});

  @override
  State<ExpenseClaimPage> createState() => _ExpenseClaimPageState();
}

class _ExpenseClaimPageState extends State<ExpenseClaimPage> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _employeeController = TextEditingController();
  final _approverController = TextEditingController();
  final _employeeFocusNode = FocusNode();
  final _approverFocusNode = FocusNode();
  final _picker = ImagePicker();

  ExpenseClaimFormOptions? _options;
  ExpenseClaimOption? _selectedEmployee;
  ExpenseClaimOption? _selectedApprover;
  String? _expenseType;
  DateTime _expenseDate = DateTime.now();
  XFile? _bill;
  bool _loading = true;
  bool _loadingApprovers = false;
  bool _submitting = false;
  int _approverRequest = 0;
  String? _error;
  String? _approverError;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _descriptionController.dispose();
    _employeeController.dispose();
    _approverController.dispose();
    _employeeFocusNode.dispose();
    _approverFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    setState(() {
      _loading = true;
      _error = null;
      _approverError = null;
    });
    try {
      final options = await ExpenseClaimApi.loadFormOptions();
      if (!mounted) return;
      setState(() {
        _options = options;
        _selectedEmployee = _findOption(
          options.employees,
          options.defaultEmployee,
        );
        _selectedApprover = _findOption(
          options.expenseApprovers,
          options.defaultExpenseApprover,
        );
        _employeeController.text = _selectedEmployee?.label ?? '';
        _approverController.text = _selectedApprover?.label ?? '';
        if (!options.expenseTypes.any((item) => item.value == _expenseType)) {
          _expenseType = options.expenseTypes.first.value;
        }
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _cleanError(error);
      });
    }
  }

  ExpenseClaimOption? _findOption(
    List<ExpenseClaimOption> options,
    String value,
  ) {
    for (final option in options) {
      if (option.value == value) return option;
    }
    return null;
  }

  Future<void> _selectEmployee(ExpenseClaimOption? employee) async {
    final request = ++_approverRequest;
    setState(() {
      _selectedEmployee = employee;
      _selectedApprover = null;
      _approverController.clear();
      _loadingApprovers = employee != null;
      _approverError = null;
    });
    if (employee == null) return;

    try {
      final options = await ExpenseClaimApi.loadFormOptions(
        employee: employee.value,
      );
      if (!mounted ||
          request != _approverRequest ||
          _selectedEmployee?.value != employee.value) {
        return;
      }
      final approver = _findOption(
        options.expenseApprovers,
        options.defaultExpenseApprover,
      );
      setState(() {
        _options = options;
        _selectedApprover = approver;
        _approverController.text = approver?.label ?? '';
        _loadingApprovers = false;
      });
    } catch (error) {
      if (!mounted || request != _approverRequest) return;
      setState(() {
        _loadingApprovers = false;
        _approverError = _cleanError(error);
      });
    }
  }

  void _selectApprover(ExpenseClaimOption? approver) {
    setState(() => _selectedApprover = approver);
  }

  String _cleanError(Object error) =>
      error.toString().replaceFirst(RegExp(r'^(Bad state|StateError):\s*'), '');

  Future<void> _pickBill(ImageSource source) async {
    try {
      final selected = await _picker.pickImage(
        source: source,
        imageQuality: 88,
        maxWidth: 2200,
      );
      if (selected != null && mounted) setState(() => _bill = selected);
    } catch (error) {
      if (mounted) _showMessage('Could not open the image picker: $error');
    }
  }

  Future<void> _showBillPicker() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder:
          (sheetContext) => SafeArea(
            child: Wrap(
              children: [
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Take photo'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _pickBill(ImageSource.camera);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Choose from gallery'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _pickBill(ImageSource.gallery);
                  },
                ),
              ],
            ),
          ),
    );
  }

  Future<void> _chooseDate() async {
    final today = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: _expenseDate,
      firstDate: DateTime(today.year - 10),
      lastDate: DateTime(today.year + 1, 12, 31),
      builder:
          (context, child) => Theme(
            data: Theme.of(context).copyWith(
              colorScheme: Theme.of(
                context,
              ).colorScheme.copyWith(primary: _expenseBlue),
            ),
            child: child!,
          ),
    );
    if (selected != null && mounted) setState(() => _expenseDate = selected);
  }

  Future<void> _submit() async {
    if (_submitting || _options == null) return;
    if (!_formKey.currentState!.validate()) return;
    if (_bill == null) {
      _showMessage('Attach a bill photo before submitting.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await ExpenseClaimApi.submitClaim(
        employee: _selectedEmployee?.value ?? '',
        expenseApprover: _selectedApprover?.value ?? '',
        expenseType: _expenseType ?? '',
        amount: _amountController.text.trim().replaceAll(',', ''),
        expenseDate: DateFormat('yyyy-MM-dd').format(_expenseDate),
        description: _descriptionController.text.trim(),
        csrfToken: _options!.csrfToken,
        billPath: _bill!.path,
      );
      if (!mounted) return;
      _clearForm();
      _showMessage(
        'Expense Claim ${result.name} was created with its bill attached.',
      );
    } catch (error) {
      if (!mounted) return;
      if (error is TimeoutException) {
        _showMessage(
          'Submission timed out. The claim and bill may still have been saved. Check Expense Claims before retrying.',
        );
      } else {
        _showMessage(_cleanError(error));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _clearForm() {
    _amountController.clear();
    _descriptionController.clear();
    setState(() {
      _bill = null;
      _expenseDate = DateTime.now();
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  InputDecoration _inputDecoration({String? hint, Widget? suffixIcon}) =>
      InputDecoration(
        hintText: hint,
        suffixIcon: suffixIcon,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: const BorderSide(color: _expenseBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: const BorderSide(color: _expenseBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: const BorderSide(color: _expenseBlue, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(11),
          borderSide: const BorderSide(color: Colors.redAccent),
        ),
      );

  Widget _fieldLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: RichText(
      text: TextSpan(
        style: const TextStyle(
          color: _expenseInk,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        children: [
          TextSpan(text: text),
          const TextSpan(
            text: ' *',
            style: TextStyle(color: Color(0xFFC74A55)),
          ),
        ],
      ),
    ),
  );

  Widget _formField(String label, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_fieldLabel(label), child],
    ),
  );

  Widget _searchableDropdown({
    required TextEditingController controller,
    required FocusNode focusNode,
    required List<ExpenseClaimOption> options,
    required ExpenseClaimOption? selected,
    required String hint,
    required ValueChanged<ExpenseClaimOption?> onChanged,
    bool loading = false,
    bool enabled = true,
    String? loadError,
  }) {
    return RawAutocomplete<ExpenseClaimOption>(
      textEditingController: controller,
      focusNode: focusNode,
      displayStringForOption: (option) => option.label,
      optionsBuilder: (textEditingValue) {
        final query = textEditingValue.text.trim().toLowerCase();
        return options
            .where((option) {
              return query.isEmpty ||
                  option.label.toLowerCase().contains(query) ||
                  option.value.toLowerCase().contains(query);
            })
            .take(30);
      },
      onSelected: onChanged,
      fieldViewBuilder: (context, textController, fieldFocusNode, onSubmit) {
        return TextFormField(
          controller: textController,
          focusNode: fieldFocusNode,
          enabled: !_submitting && !loading && enabled && loadError == null,
          decoration: _inputDecoration(
            hint: hint,
            suffixIcon:
                loading
                    ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                    : const Icon(Icons.keyboard_arrow_down_rounded),
          ).copyWith(errorText: loadError),
          validator: (_) {
            if (loadError != null) return loadError;
            if (selected == null)
              return 'Choose an option from the suggestions.';
            return null;
          },
          onChanged: (text) {
            if (selected != null && text != selected.label) onChanged(null);
          },
          textInputAction: TextInputAction.search,
        );
      },
      optionsViewBuilder: (context, onSelected, suggestions) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240, maxWidth: 520),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: suggestions.length,
                itemBuilder: (context, index) {
                  final option = suggestions.elementAt(index);
                  return ListTile(
                    dense: true,
                    title: Text(option.label),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildForm() {
    final options = _options!;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _formField(
            'Employee',
            _searchableDropdown(
              controller: _employeeController,
              focusNode: _employeeFocusNode,
              options: options.employees,
              selected: _selectedEmployee,
              hint: 'Select or type employee name',
              onChanged: _selectEmployee,
            ),
          ),
          _formField(
            'Expense Approver',
            _searchableDropdown(
              controller: _approverController,
              focusNode: _approverFocusNode,
              options: options.expenseApprovers,
              selected: _selectedApprover,
              hint: 'Select or type approver name',
              loading: _loadingApprovers,
              enabled: _selectedEmployee != null,
              loadError: _approverError,
              onChanged: _selectApprover,
            ),
          ),
          _formField(
            'Expense Type',
            DropdownButtonFormField<String>(
              value: _expenseType,
              decoration: _inputDecoration(),
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
              items:
                  options.expenseTypes
                      .map(
                        (item) => DropdownMenuItem(
                          value: item.value,
                          child: Text(
                            item.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
              onChanged:
                  _submitting
                      ? null
                      : (value) => setState(() => _expenseType = value),
              validator:
                  (value) =>
                      value == null || value.isEmpty
                          ? 'Choose an expense type.'
                          : null,
            ),
          ),
          _formField(
            'Amount${options.currency.isEmpty ? '' : ' (${options.currency})'}',
            TextFormField(
              controller: _amountController,
              enabled: !_submitting,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: _inputDecoration(hint: 'Enter amount'),
              validator: (value) {
                final parsed = double.tryParse(
                  (value ?? '').replaceAll(',', '').trim(),
                );
                if (parsed == null || parsed <= 0) {
                  return 'Enter an amount greater than zero.';
                }
                return null;
              },
            ),
          ),
          _formField(
            'Date',
            InkWell(
              onTap: _submitting ? null : _chooseDate,
              borderRadius: BorderRadius.circular(11),
              child: InputDecorator(
                decoration: _inputDecoration(
                  suffixIcon: const Icon(
                    Icons.calendar_month_outlined,
                    color: _expenseBlue,
                  ),
                ),
                child: Text(DateFormat('dd MMM yyyy').format(_expenseDate)),
              ),
            ),
          ),
          _formField(
            'Description',
            TextFormField(
              controller: _descriptionController,
              enabled: !_submitting,
              minLines: 1,
              maxLines: 3,
              decoration: _inputDecoration(hint: 'Enter expense details'),
              validator:
                  (value) =>
                      (value ?? '').trim().isEmpty
                          ? 'Description is required.'
                          : null,
            ),
          ),
          _formField('Attach Bill', _buildBillPicker()),
          SizedBox(
            height: 50,
            child: FilledButton(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: _expenseBlue,
                disabledBackgroundColor: _expenseBlue.withValues(alpha: 0.65),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child:
                  _submitting
                      ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                      : const Text(
                        'Submit Claim',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBillPicker() => Row(
    children: [
      if (_bill != null)
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            children: [
              Image.file(
                File(_bill!.path),
                width: 104,
                height: 100,
                fit: BoxFit.cover,
              ),
              Positioned(
                right: 2,
                top: 2,
                child: IconButton.filledTonal(
                  visualDensity: VisualDensity.compact,
                  onPressed:
                      _submitting ? null : () => setState(() => _bill = null),
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ),
            ],
          ),
        ),
      if (_bill != null) const SizedBox(width: 12),
      Expanded(
        child: InkWell(
          onTap: _submitting ? null : _showBillPicker,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 100,
            decoration: BoxDecoration(
              color: const Color(0xFFF5F9FF),
              border: Border.all(color: const Color(0xFFB9D1F0)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.add_rounded, color: _expenseBlue, size: 30),
                const SizedBox(height: 4),
                Text(
                  _bill == null ? 'Add Photo' : 'Replace Photo',
                  style: const TextStyle(
                    color: _expenseBlue,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        leading: const HomeBackButton(color: _expenseBlue),
        title: const Text(
          'Expense Claim',
          style: TextStyle(
            color: _expenseInk,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child:
            _loading
                ? const Center(
                  child: CircularProgressIndicator(color: _expenseBlue),
                )
                : _error != null
                ? Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.receipt_long_outlined,
                          color: _expenseBlue,
                          size: 42,
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'Could not load expense options',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFF606B79),
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextButton.icon(
                          onPressed: _loadOptions,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
                : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                  child: _buildForm(),
                ),
      ),
    );
  }
}
