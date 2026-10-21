import 'package:flutter/foundation.dart';
import '../utils/widget/camera_service.dart';
import '../utils/platform/file_image.dart';
import '../utils/widget/pull_to_refresh.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'dart:async';
import 'package:homegenie/utils/platform/platform_file.dart';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../utils/api/expense_claim_api.dart';
import '../utils/widget/home_back_button.dart';

const _expenseBlue = BrandColors.ink;
const _expenseInk = Color(0xFF26313F);
const _expenseBorder = Color(0xFFD9DEE5);

class _ExpenseRowDraft {
  final amountController = TextEditingController();
  final descriptionController = TextEditingController();
  String? expenseType;
  DateTime expenseDate = DateTime.now();

  _ExpenseRowDraft({this.expenseType});

  void dispose() {
    amountController.dispose();
    descriptionController.dispose();
  }
}

class ExpenseClaimPage extends StatefulWidget {
  const ExpenseClaimPage({super.key});

  @override
  State<ExpenseClaimPage> createState() => _ExpenseClaimPageState();
}

class _ExpenseClaimPageState extends State<ExpenseClaimPage> {
  final _formKey = GlobalKey<FormState>();
  final _expenses = <_ExpenseRowDraft>[_ExpenseRowDraft()];
  final _bills = <XFile>[];
  final _employeeController = TextEditingController();
  final _approverController = TextEditingController();
  final _employeeFocusNode = FocusNode();
  final _approverFocusNode = FocusNode();
  final _picker = ImagePicker();

  ExpenseClaimFormOptions? _options;
  ExpenseClaimOption? _selectedEmployee;
  ExpenseClaimOption? _selectedApprover;
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
    for (final row in _expenses) {
      row.dispose();
    }
    _employeeController.dispose();
    _approverController.dispose();
    _employeeFocusNode.dispose();
    _approverFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    if (_submitting || _loadingApprovers) return;
    setState(() {
      _loading = true;
      _error = null;
      _approverError = null;
    });
    try {
      final options = await ExpenseClaimApi.loadFormOptions(
        employee: _selectedEmployee?.value,
      );
      if (!mounted) return;
      setState(() {
        _options = options;
        _selectedEmployee = _findOption(
          options.employees,
          _selectedEmployee?.value ?? options.defaultEmployee,
        );
        _selectedApprover = _findOption(
          options.expenseApprovers,
          _selectedApprover?.value ?? options.defaultExpenseApprover,
        );
        _employeeController.text = _selectedEmployee?.label ?? '';
        _approverController.text = _selectedApprover?.label ?? '';
        _syncExpenseTypes(options);
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

  void _syncExpenseTypes(ExpenseClaimFormOptions options) {
    for (final row in _expenses) {
      if (!options.expenseTypes.any((item) => item.value == row.expenseType)) {
        row.expenseType = options.expenseTypes.first.value;
      }
    }
  }

  void _addExpense() {
    if (_submitting || _loadingApprovers) return;
    if (!_options!.supportsMultipleExpenses) {
      _showMessage(
        'Multiple expenses are not available yet. Contact your administrator to enable them.',
      );
      return;
    }
    setState(
      () => _expenses.add(
        _ExpenseRowDraft(expenseType: _options!.expenseTypes.first.value),
      ),
    );
  }

  void _removeExpense(_ExpenseRowDraft row) {
    if (_submitting || _expenses.length == 1) return;
    setState(() => _expenses.remove(row));
    WidgetsBinding.instance.addPostFrameCallback((_) => row.dispose());
  }

  double get _totalAmount => _expenses.fold(0, (total, row) {
    final amount = double.tryParse(
      row.amountController.text.trim().replaceAll(',', ''),
    );
    return total +
        (amount != null && amount.isFinite && amount > 0 ? amount : 0);
  });

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
        _syncExpenseTypes(options);
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
      final multiple = _options!.supportsMultipleExpenses;
      final List<XFile> selected;
      if (kIsWeb && source == ImageSource.camera) {
        final photo = await CameraService.capturePhoto();
        selected = photo == null ? [] : [XFile.fromData(await photo.readAsBytes(), name: 'bill.jpg', mimeType: 'image/jpeg')];
      } else if (source == ImageSource.gallery && multiple) {
        selected = await _picker.pickMultiImage(
          imageQuality: 88,
          maxWidth: 2200,
        );
      } else {
        final image = await _picker.pickImage(
          source: source,
          imageQuality: 88,
          maxWidth: 2200,
        );
        selected = image == null ? [] : [image];
      }
      if (kIsWeb) {
        for (final bill in selected) {
          await File(bill.path).writeAsBytes(await bill.readAsBytes());
        }
      }
      if (selected.isNotEmpty && mounted && !_submitting) {
        setState(() {
          if (!multiple) _bills.clear();
          for (final bill in selected) {
            if (!_bills.any((existing) => existing.path == bill.path)) {
              _bills.add(bill);
            }
          }
        });
      }
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

  Future<void> _chooseDate(_ExpenseRowDraft row) async {
    final today = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: row.expenseDate,
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
    if (selected != null &&
        mounted &&
        _expenses.contains(row) &&
        !_submitting) {
      setState(() => row.expenseDate = selected);
    }
  }

  Future<void> _submit() async {
    if (_submitting || _loadingApprovers || _options == null) return;
    if (!_formKey.currentState!.validate()) return;
    if (_bills.isEmpty) {
      _showMessage('Attach a bill photo before submitting.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final expenseCount = _expenses.length;
      final billCount = _bills.length;
      final result = await ExpenseClaimApi.submitExpenses(
        employee: _selectedEmployee?.value ?? '',
        expenseApprover: _selectedApprover?.value ?? '',
        expenses:
            _expenses
                .map(
                  (row) => ExpenseClaimLine(
                    expenseType: row.expenseType ?? '',
                    amount: row.amountController.text,
                    expenseDate: DateFormat(
                      'yyyy-MM-dd',
                    ).format(row.expenseDate),
                    description: row.descriptionController.text,
                  ),
                )
                .toList(),
        csrfToken: _options!.csrfToken,
        billPaths: _bills.map((bill) => bill.path).toList(),
        supportsMultipleExpenses: _options!.supportsMultipleExpenses,
      );
      if (!mounted) return;
      _clearForm();
      _showMessage(
        'Expense Claim ${result.name} was created with $expenseCount ${expenseCount == 1 ? 'expense' : 'expenses'} and $billCount ${billCount == 1 ? 'bill' : 'bills'} attached.',
      );
    } catch (error) {
      if (!mounted) return;
      if (error is TimeoutException) {
        _showMessage(
          'Submission timed out. The claim and bills may still have been saved. Check Expense Claims before retrying.',
        );
      } else {
        _showMessage(_cleanError(error));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _clearForm() {
    final previousRows = _expenses.toList();
    setState(() {
      _bills.clear();
      _expenses
        ..clear()
        ..add(_ExpenseRowDraft(expenseType: previousRows.first.expenseType));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final row in previousRows) {
        row.dispose();
      }
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
            if (selected == null) {
              return 'Choose an option from the suggestions.';
            }
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
          const Text(
            'Expenses',
            style: TextStyle(
              color: _expenseInk,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          const Text('Add each expense as a separate row in this claim.'),
          const SizedBox(height: 14),
          for (var index = 0; index < _expenses.length; index++)
            _buildExpenseRow(_expenses[index], index, options),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _submitting || _loadingApprovers ? null : _addExpense,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add Expense'),
            ),
          ),
          if (!options.supportsMultipleExpenses)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Multiple expenses and bill photos are not available yet. You can still submit one expense with one bill.',
              ),
            ),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 20),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F9FF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 16,
              runSpacing: 8,
              children: [
                Text(
                  'Total (${_expenses.length} ${_expenses.length == 1 ? 'expense' : 'expenses'})',
                ),
                Text(
                  '${options.currency} ${NumberFormat('#,##0.00').format(_totalAmount)}',
                  key: const ValueKey('expense-total'),
                  style: const TextStyle(
                    color: _expenseBlue,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'Attach the bill photos for this claim. At least one photo is required.',
            ),
          ),
          _formField('Attach Bills', _buildBillPicker()),
          SizedBox(
            height: 50,
            child: FilledButton(
              onPressed: _submitting || _loadingApprovers ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: _expenseBlue,
                disabledBackgroundColor: _expenseBlue.withValues(alpha: 0.65),
                shape: const StadiumBorder(),
              ).copyWith(backgroundBuilder: BrandColors.buttonBackground),
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

  Widget _buildExpenseRow(
    _ExpenseRowDraft row,
    int index,
    ExpenseClaimFormOptions options,
  ) => Container(
    key: ObjectKey(row),
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
    decoration: BoxDecoration(
      border: Border.all(color: _expenseBorder),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Expense ${index + 1}',
                style: const TextStyle(
                  color: _expenseInk,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Remove expense ${index + 1}',
              onPressed:
                  _submitting || _expenses.length == 1
                      ? null
                      : () => _removeExpense(row),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
        _formField(
          'Expense Type',
          DropdownButtonFormField<String>(
            initialValue: row.expenseType,
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
                    : (value) => setState(() => row.expenseType = value),
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
            key: ObjectKey(row.amountController),
            controller: row.amountController,
            onChanged: (_) => setState(() {}),
            enabled: !_submitting,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: _inputDecoration(hint: 'Enter amount'),
            validator: (value) {
              final parsed = double.tryParse(
                (value ?? '').replaceAll(',', '').trim(),
              );
              if (parsed == null || !parsed.isFinite || parsed <= 0) {
                return 'Enter an amount greater than zero.';
              }
              return null;
            },
          ),
        ),
        _formField(
          'Date',
          InkWell(
            onTap: _submitting ? null : () => _chooseDate(row),
            borderRadius: BorderRadius.circular(11),
            child: InputDecorator(
              decoration: _inputDecoration(
                suffixIcon: const Icon(
                  Icons.calendar_month_outlined,
                  color: _expenseBlue,
                ),
              ),
              child: Text(DateFormat('dd MMM yyyy').format(row.expenseDate)),
            ),
          ),
        ),
        _formField(
          'Description',
          TextFormField(
            key: ObjectKey(row.descriptionController),
            controller: row.descriptionController,
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
      ],
    ),
  );

  Widget _buildBillPicker() => Wrap(
    spacing: 12,
    runSpacing: 12,
    children: [
      for (var index = 0; index < _bills.length; index++)
        ClipRRect(
          key: ValueKey(_bills[index].path),
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            children: [
              Image(
                image: fileImage(File(_bills[index].path)),
                width: 104,
                height: 100,
                fit: BoxFit.cover,
                errorBuilder:
                    (context, error, stackTrace) => const SizedBox(
                      width: 104,
                      height: 100,
                      child: Icon(Icons.broken_image_outlined),
                    ),
              ),
              Positioned(
                right: 2,
                top: 2,
                child: IconButton.filledTonal(
                  tooltip: 'Remove bill ${index + 1}',
                  visualDensity: VisualDensity.compact,
                  onPressed:
                      _submitting
                          ? null
                          : () => setState(() => _bills.removeAt(index)),
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ),
            ],
          ),
        ),
      InkWell(
        onTap: _submitting ? null : _showBillPicker,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 140,
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
                _bills.isNotEmpty && !_options!.supportsMultipleExpenses
                    ? 'Replace Photo'
                    : 'Add Photos',
                style: const TextStyle(
                  color: _expenseBlue,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: brandAppBar(
        elevation: 0,
        leading: const HomeBackButton(color: Colors.white),
        title: const Text(
          'Expense Claim',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: PullToRefresh(
        enabled: !_loading && !_submitting && !_loadingApprovers,
        onRefresh: _loadOptions,
        child: SafeArea(
          top: false,
          child:
              _loading
                  ? const Center(child: AgPathLoadingIndicator())
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
                        ],
                      ),
                    ),
                  )
                  : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                    child: _buildForm(),
                  ),
        ),
      ),
    );
  }
}
