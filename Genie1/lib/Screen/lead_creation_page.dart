import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../utils/api/lead_api.dart';
import '../utils/api/location_api.dart';
import '../utils/widget/home_back_button.dart';
import '../utils/widget/warning.dart';

const _leadBlue = BrandColors.ink;
const _leadInk = Color(0xFF202B3C);

class LeadCreationPage extends StatefulWidget {
  const LeadCreationPage({super.key});

  @override
  State<LeadCreationPage> createState() => _LeadCreationPageState();
}

class _LeadCreationPageState extends State<LeadCreationPage> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _mobileController = TextEditingController();
  final _locationController = TextEditingController();
  final _requirementController = TextEditingController();

  LeadFormOptions? _options;
  String? _selectedCategory;
  String? _selectedSource;
  bool _checkDuplicates = true;
  bool _loadingOptions = true;
  bool _gettingLocation = false;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _mobileController.dispose();
    _locationController.dispose();
    _requirementController.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    setState(() {
      _loadingOptions = true;
      _error = null;
      _options = null;
      _selectedCategory = null;
      _selectedSource = null;
    });
    try {
      final options = await LeadApi.getFormOptions();
      if (!mounted) return;
      setState(() {
        _options = options;
        _loadingOptions = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingOptions = false;
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await LeadApi.createLead(
        firstName: _firstNameController.text,
        mobileNo: _mobileController.text,
        requirement: _requirementController.text,
        source: _selectedSource ?? '',
        productCategory: _selectedCategory ?? '',
        address: _locationController.text,
        csrfToken: _options!.csrfToken ?? '',
      );
      if (!mounted) return;

      _firstNameController.clear();
      _mobileController.clear();
      _locationController.clear();
      _requirementController.clear();
      Warning.show(context, 'Lead created successfully!', 'Success');
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _getCurrentLocation() async {
    if (_gettingLocation) return;
    setState(() => _gettingLocation = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError('Turn on location services and try again.');
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError('Location permission is required.');
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      final address = await LocationHelper.getAddressFromCoordinates(
        position.latitude,
        position.longitude,
      );
      if (!mounted) return;
      _locationController.text = address;
    } catch (error) {
      if (mounted) {
        Warning.show(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
          'Location',
        );
      }
    } finally {
      if (mounted) setState(() => _gettingLocation = false);
    }
  }

  Widget _fieldLabel(String label) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text.rich(
      TextSpan(
        text: label,
        style: const TextStyle(
          color: _leadInk,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        children: const [
          TextSpan(text: ' *', style: TextStyle(color: Color(0xFFE34B56))),
        ],
      ),
    ),
  );

  InputDecoration _fieldDecoration({
    String? hint,
    Widget? suffixIcon,
  }) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Color(0xFF858D98), fontSize: 13),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
    suffixIcon: suffixIcon,
    suffixIconConstraints: const BoxConstraints(minWidth: 42, minHeight: 42),
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: Color(0xFFD8DEE7)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: Color(0xFFD8DEE7)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: _leadBlue, width: 1.4),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: const BorderSide(color: Colors.redAccent),
    ),
  );

  Widget _dropdownField({
    required String label,
    required String? value,
    required List<String> options,
    required bool enabled,
    required ValueChanged<String?> onChanged,
    required FormFieldValidator<String> validator,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _fieldLabel(label),
      DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
        decoration: _fieldDecoration(
          hint: enabled ? 'Select $label' : 'Options unavailable',
        ),
        items:
            options
                .map(
                  (option) => DropdownMenuItem(
                    value: option,
                    child: Text(option, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
        onChanged: enabled ? onChanged : null,
        validator: validator,
      ),
    ],
  );

  Widget _optionsLoadState() {
    if (_loadingOptions) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 72),
        child: Column(
          children: [
            AgPathLoadingIndicator(),
            SizedBox(height: 16),
            Text(
              'Loading Lead Source and Product Category…',
              textAlign: TextAlign.center,
              style: TextStyle(color: _leadInk, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 28),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4F2),
        border: Border.all(color: const Color(0xFFF2C7C1)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Could not load form options',
            style: TextStyle(
              color: _leadInk,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _error ?? 'The server did not return Lead form options.',
            style: const TextStyle(
              color: Color(0xFF9D3028),
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Ask your Frappe administrator to configure the named Lead field, then retry.',
            style: TextStyle(color: _leadInk, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _loadOptions,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Retry'),
            style: TextButton.styleFrom(
              foregroundColor: _leadBlue,
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: brandAppBar(
        leading: const HomeBackButton(color: Colors.white),
        elevation: 0,
        title: const Text(
          'Create Lead',
          style: TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Reload form',
            onPressed: _loadingOptions || _submitting ? null : _loadOptions,
            icon: const Icon(Icons.refresh_rounded),
            color: Colors.white,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadOptions,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 13, 20, 24),
          children: [
            if (_options == null)
              _optionsLoadState()
            else
              Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _fieldLabel('Customer Name'),
                    TextFormField(
                      controller: _firstNameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: _fieldDecoration(hint: 'ABC Constructions'),
                      validator:
                          (value) =>
                              value == null || value.trim().isEmpty
                                  ? 'Enter the customer name.'
                                  : null,
                    ),
                    const SizedBox(height: 15),
                    _fieldLabel('Phone Number'),
                    TextFormField(
                      controller: _mobileController,
                      keyboardType: TextInputType.phone,
                      decoration: _fieldDecoration(
                        hint: '+91 98765 43210',
                        suffixIcon: const Icon(
                          Icons.search_rounded,
                          color: _leadBlue,
                          size: 22,
                        ),
                      ),
                      validator:
                          (value) =>
                              value == null || value.trim().isEmpty
                                  ? 'Enter the phone number.'
                                  : null,
                    ),
                    const SizedBox(height: 15),
                    _dropdownField(
                      label: 'Product Category',
                      value: _selectedCategory,
                      options: _options!.productCategoryOptions,
                      enabled: !_loadingOptions,
                      onChanged:
                          (value) => setState(() => _selectedCategory = value),
                      validator:
                          (value) =>
                              value == null
                                  ? 'Select a product category.'
                                  : null,
                    ),
                    const SizedBox(height: 15),
                    _dropdownField(
                      label: 'Lead Source',
                      value: _selectedSource,
                      options: _options!.sourceOptions,
                      enabled: !_loadingOptions,
                      onChanged:
                          (value) => setState(() => _selectedSource = value),
                      validator:
                          (value) =>
                              value == null ? 'Select a lead source.' : null,
                    ),
                    const SizedBox(height: 15),
                    _fieldLabel('Location'),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _locationController,
                            textCapitalization: TextCapitalization.words,
                            decoration: _fieldDecoration(hint: 'Chennai'),
                            validator:
                                (value) =>
                                    value == null || value.trim().isEmpty
                                        ? 'Enter or get the location.'
                                        : null,
                          ),
                        ),
                        const SizedBox(width: 7),
                        OutlinedButton.icon(
                          onPressed:
                              _gettingLocation ? null : _getCurrentLocation,
                          icon:
                              _gettingLocation
                                  ? const SizedBox(
                                    width: 15,
                                    height: 15,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                  : const Icon(
                                    Icons.my_location_rounded,
                                    size: 16,
                                  ),
                          label: const Text('Get Location'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _leadBlue,
                            side: const BorderSide(color: Color(0xFFDCE4EE)),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(0, 47),
                            textStyle: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                            shape: const StadiumBorder(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 15),
                    _fieldLabel('Requirement'),
                    TextFormField(
                      controller: _requirementController,
                      minLines: 2,
                      maxLines: 3,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: _fieldDecoration(
                        hint: '200 KLD STP for residential project',
                      ),
                      validator:
                          (value) =>
                              value == null || value.trim().isEmpty
                                  ? 'Enter the requirement.'
                                  : null,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        SizedBox(
                          width: 28,
                          height: 32,
                          child: Checkbox(
                            value: _checkDuplicates,
                            activeColor: _leadBlue,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            onChanged:
                                (value) => setState(
                                  () => _checkDuplicates = value ?? false,
                                ),
                          ),
                        ),
                        const SizedBox(width: 5),
                        const Text(
                          'Check for duplicates',
                          style: TextStyle(
                            color: _leadInk,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    if (_error != null && _options != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 13,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 48,
                      child: FilledButton(
                        onPressed:
                            _options == null || _loadingOptions || _submitting
                                ? null
                                : _submit,
                        style: FilledButton.styleFrom(
                          backgroundColor: _leadBlue,
                          foregroundColor: Colors.white,
                          shape: const StadiumBorder(),
                        ).copyWith(
                          backgroundBuilder: BrandColors.buttonBackground,
                        ),
                        child:
                            _submitting
                                ? const SizedBox(
                                  width: 19,
                                  height: 19,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                                : const Text(
                                  'Create Lead',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                      ),
                    ),
                    if (_loadingOptions)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
