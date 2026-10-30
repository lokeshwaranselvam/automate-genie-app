import '../utils/widget/pull_to_refresh.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import '../utils/api_business_policy.dart';
import 'package:geolocator/geolocator.dart';

import '../utils/api/lead_api.dart';
import '../utils/lead_phone_number.dart';
import '../utils/api/location_api.dart';
import '../utils/widget/home_back_button.dart';
import '../utils/widget/warning.dart';

const _leadBlue = BrandColors.ink;
const _leadInk = Color(0xFF202B3C);

/// Searchable ERP choices; text outside the supplied choices cannot be saved.
class _LeadOptionField extends StatefulWidget {
  const _LeadOptionField({
    super.key,
    required this.value,
    required this.options,
    required this.enabled,
    required this.decoration,
    required this.onChanged,
    required this.validator,
  });
  final String? value;
  final List<String> options;
  final bool enabled;
  final InputDecoration decoration;
  final ValueChanged<String?> onChanged;
  final FormFieldValidator<String> validator;

  @override
  State<_LeadOptionField> createState() => _LeadOptionFieldState();
}

class _LeadOptionFieldState extends State<_LeadOptionField> {
  late final _controller = TextEditingController(text: widget.value ?? '');
  final _focus = FocusNode();

  @override
  void didUpdateWidget(covariant _LeadOptionField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value &&
        _controller.text != (widget.value ?? '')) {
      // Keep a query while searching; explicit selections/default changes win.
      if (widget.value != null || !_focus.hasFocus) {
        _controller.text = widget.value ?? '';
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder:
        (context, constraints) => RawAutocomplete<String>(
          textEditingController: _controller,
          focusNode: _focus,
          optionsBuilder:
              (value) =>
                  !widget.enabled
                      ? const Iterable<String>.empty()
                      : widget.options.where(
                        (option) => option.toLowerCase().contains(
                          value.text.trim().toLowerCase(),
                        ),
                      ),
          onSelected: (value) => widget.onChanged(value),
          fieldViewBuilder:
              (context, controller, focus, submit) => TextFormField(
                controller: controller,
                focusNode: focus,
                readOnly: !widget.enabled,
                decoration: widget.decoration,
                validator: (_) => widget.validator(controller.text.trim()),
                onChanged:
                    (text) => widget.onChanged(
                      widget.options.contains(text.trim()) ? text.trim() : null,
                    ),
                onFieldSubmitted: (_) => submit(),
              ),
          optionsViewBuilder: (context, select, options) {
            final choices = options.toList();
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(9),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  width: constraints.maxWidth,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: choices.length,
                      itemBuilder:
                          (context, index) => ListTile(
                            selected:
                                AutocompleteHighlightedOption.of(context) ==
                                index,
                            title: Text(choices[index]),
                            onTap: () => select(choices[index]),
                          ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
  );
}

class LeadCreationPage extends StatefulWidget {
  const LeadCreationPage({super.key});

  @override
  State<LeadCreationPage> createState() => _LeadCreationPageState();
}

class _LeadCreationPageState extends State<LeadCreationPage> {
  ApiBusinessPolicy get _policy =>
      _options?.businessPolicy ?? ApiBusinessPolicy.empty;
  String _fieldName(String label) =>
      const {
        'Customer Name': 'first_name',
        'Phone Number': 'mobile_no',
        'WhatsApp Number': 'whatsapp_no',
        'Requirement': 'custom_requirement',
        'Location': 'custom_address',
        'Lead Source': 'source',
        'Product Enquired': 'custom_product_enquired',
        'Customer Category': 'custom_customer_category',
      }[label] ??
      label;
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _mobileController = TextEditingController();
  final _whatsappController = TextEditingController();
  final _locationController = TextEditingController();
  final _requirementController = TextEditingController();

  LeadFormOptions? _options;
  String? _selectedCategory;
  String? _selectedSource;
  String? _selectedCustomerCategory;
  bool _samePhoneAndWhatsApp = false;
  String _separateWhatsApp = '';
  bool _loadingOptions = true;
  bool _gettingLocation = false;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _mobileController.addListener(_syncWhatsApp);
    _loadOptions();
  }

  @override
  void dispose() {
    _mobileController.removeListener(_syncWhatsApp);
    _firstNameController.dispose();
    _mobileController.dispose();
    _whatsappController.dispose();
    _locationController.dispose();
    _requirementController.dispose();
    super.dispose();
  }

  void _syncWhatsApp() {
    if (_samePhoneAndWhatsApp && !_policy.readOnly('whatsapp_no')) {
      _whatsappController.value = _mobileController.value;
    }
  }

  Future<void> _loadOptions() async {
    if (_submitting) return;
    setState(() {
      _loadingOptions = true;
      _error = null;
    });
    try {
      final options = await LeadApi.getFormOptions();
      if (!mounted) return;
      setState(() {
        _options = options;
        if (_policy.readOnly('whatsapp_no')) _samePhoneAndWhatsApp = false;
        for (final entry
            in {
              'first_name': _firstNameController,
              'mobile_no': _mobileController,
              'whatsapp_no': _whatsappController,
              'custom_requirement': _requirementController,
              'custom_address': _locationController,
            }.entries) {
          _policy.applyDefault(entry.key, entry.value);
        }
        if (!options.productCategoryOptions.contains(_selectedCategory)) {
          _selectedCategory = null;
        }
        if (!options.sourceOptions.contains(_selectedSource)) {
          _selectedSource = null;
        }
        if (!options.customerCategoryOptions.contains(
          _selectedCustomerCategory,
        )) {
          _selectedCustomerCategory = null;
        }
        final customerDefault =
            _policy.field('custom_customer_category')['default']?.toString();
        if ((_selectedCustomerCategory == null ||
                _policy.readOnly('custom_customer_category')) &&
            options.customerCategoryOptions.contains(customerDefault)) {
          _selectedCustomerCategory = customerDefault;
        }
        final categoryDefault =
            _policy.field('custom_product_enquired')['default']?.toString();
        final sourceDefault = _policy.field('source')['default']?.toString();
        if ((_selectedCategory == null ||
                _policy.readOnly('custom_product_enquired')) &&
            options.productCategoryOptions.contains(categoryDefault)) {
          _selectedCategory = categoryDefault;
        }
        if ((_selectedSource == null || _policy.readOnly('source')) &&
            options.sourceOptions.contains(sourceDefault)) {
          _selectedSource = sourceDefault;
        }
        _loadingOptions = false;
        _syncWhatsApp();
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
    if (_submitting || _loadingOptions || _options == null) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await LeadApi.createLead(
        firstName: _firstNameController.text,
        mobileNo: _mobileController.text,
        whatsappNo: _whatsappController.text,
        requirement: _requirementController.text,
        source: _selectedSource ?? '',
        productCategory: _selectedCategory ?? '',
        customerCategory: _selectedCustomerCategory ?? '',
        address: _locationController.text,
        csrfToken: _options!.csrfToken ?? '',
        businessPolicy: _policy,
      );
      if (!mounted) return;

      _firstNameController.clear();
      _mobileController.clear();
      _whatsappController.clear();
      _separateWhatsApp = '';
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
          timeLimit: Duration(seconds: 15),
        ),
      );
      final address = await LocationHelper.getAddressFromCoordinates(
        position.latitude,
        position.longitude,
      ).timeout(
        const Duration(seconds: 10),
        onTimeout:
            () =>
                throw StateError(
                  'Could not find the address in time. Try again or type it.',
                ),
      );
      if (!mounted) return;
      _locationController.text = address;
    } on TimeoutException {
      if (mounted) {
        Warning.show(
          context,
          'Could not get your GPS location in time. Move to an open area and try again.',
          'Location',
        );
      }
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

  Widget _fieldLabel(String label, {bool required = true}) =>
      !_policy.visible(_fieldName(label))
          ? const SizedBox.shrink()
          : Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text.rich(
              TextSpan(
                text: label,
                style: const TextStyle(
                  color: _leadInk,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                children: [
                  if (_policy.required(_fieldName(label), required))
                    const TextSpan(
                      text: ' *',
                      style: TextStyle(color: Color(0xFFE34B56)),
                    ),
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
  }) =>
      !_policy.visible(_fieldName(label))
          ? const SizedBox.shrink()
          : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _fieldLabel(label, required: label != 'Customer Category'),
              _LeadOptionField(
                key: ValueKey(_fieldName(label)),
                value: value,
                options: options,
                enabled:
                    enabled &&
                    !_submitting &&
                    !_policy.readOnly(_fieldName(label)),
                decoration: _fieldDecoration(
                  hint: enabled ? 'Select $label' : 'Options unavailable',
                  suffixIcon: const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 20,
                  ),
                ),
                onChanged: onChanged,
                validator:
                    (value) =>
                        value != null &&
                                value.isNotEmpty &&
                                !options.contains(value)
                            ? 'Choose $label from the configured options.'
                            : _policy.hasField(_fieldName(label))
                            ? _policy.validate(_fieldName(label), value)
                            : validator(
                              value == null || value.isEmpty ? null : value,
                            ),
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
              'Loading Lead form options…',
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
      ),
      body: PullToRefresh(
        enabled: !_loadingOptions && !_submitting,
        onRefresh: _loadOptions,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
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
                    BusinessPolicyField(
                      policy: _policy,
                      name: 'first_name',
                      child: TextFormField(
                        controller: _firstNameController,
                        maxLength: _policy.maxLength('first_name'),
                        readOnly: _policy.readOnly('first_name'),
                        textCapitalization: TextCapitalization.words,
                        decoration: _fieldDecoration(hint: 'ABC Constructions'),
                        validator:
                            (value) => _policy.validate(
                              'first_name',
                              value,
                              legacyRequired: true,
                              requiredMessage: 'Enter the customer name.',
                            ),
                      ),
                    ),
                    const SizedBox(height: 15),
                    _fieldLabel('Phone Number'),
                    BusinessPolicyField(
                      policy: _policy,
                      name: 'mobile_no',
                      child: TextFormField(
                        controller: _mobileController,
                        maxLength: _policy.maxLength('mobile_no'),
                        readOnly: _policy.readOnly('mobile_no'),
                        keyboardType: TextInputType.phone,
                        decoration: _fieldDecoration(hint: '+91 98765 43210'),
                        validator:
                            (value) => _policy.validate(
                              'mobile_no',
                              value,
                              legacyRequired: true,
                              requiredMessage: 'Enter the phone number.',
                            ),
                      ),
                    ),
                    if (_policy.visible('mobile_no') &&
                        _policy.visible('whatsapp_no') &&
                        !_policy.readOnly('whatsapp_no'))
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text(
                          'Phone and WhatsApp numbers are the same',
                          style: TextStyle(fontSize: 13),
                        ),
                        value: _samePhoneAndWhatsApp,
                        onChanged:
                            _submitting
                                ? null
                                : (checked) {
                                  setState(() {
                                    if (checked == true) {
                                      _separateWhatsApp =
                                          _whatsappController.text;
                                      _samePhoneAndWhatsApp = true;
                                      _syncWhatsApp();
                                    } else {
                                      _samePhoneAndWhatsApp = false;
                                      _whatsappController.text =
                                          _separateWhatsApp;
                                    }
                                  });
                                },
                      ),
                    const SizedBox(height: 15),
                    _fieldLabel('WhatsApp Number'),
                    BusinessPolicyField(
                      policy: _policy,
                      name: 'whatsapp_no',
                      child: TextFormField(
                        controller: _whatsappController,
                        maxLength: _policy.maxLength('whatsapp_no'),
                        readOnly:
                            _samePhoneAndWhatsApp ||
                            _policy.readOnly('whatsapp_no'),
                        keyboardType: TextInputType.phone,
                        autofillHints: const [AutofillHints.telephoneNumber],
                        decoration: _fieldDecoration(hint: '+91 98765 43210'),
                        validator:
                            (value) =>
                                (value ?? '').trim().isEmpty &&
                                        !_policy.required('whatsapp_no', true)
                                    ? null
                                    : (_policy.validate('whatsapp_no', value) ??
                                        LeadPhoneNumber.validateWhatsApp(
                                          value,
                                        )),
                      ),
                    ),
                    const SizedBox(height: 15),
                    _dropdownField(
                      label: 'Product Enquired',
                      value: _selectedCategory,
                      options: _policy.options(
                        'custom_product_enquired',
                        _options!.productCategoryOptions,
                      ),
                      enabled: !_loadingOptions,
                      onChanged:
                          (value) => setState(() => _selectedCategory = value),
                      validator:
                          (value) =>
                              value == null
                                  ? 'Select a product enquired.'
                                  : null,
                    ),
                    const SizedBox(height: 15),
                    _dropdownField(
                      label: 'Lead Source',
                      value: _selectedSource,
                      options: _policy.options(
                        'source',
                        _options!.sourceOptions,
                      ),
                      enabled: !_loadingOptions,
                      onChanged:
                          (value) => setState(() => _selectedSource = value),
                      validator:
                          (value) =>
                              value == null ? 'Select a lead source.' : null,
                    ),
                    const SizedBox(height: 15),
                    _dropdownField(
                      label: 'Customer Category',
                      value: _selectedCustomerCategory,
                      options: _policy.options(
                        'custom_customer_category',
                        _options!.customerCategoryOptions,
                      ),
                      enabled: !_loadingOptions,
                      onChanged:
                          (value) =>
                              setState(() => _selectedCustomerCategory = value),
                      validator: (_) => null,
                    ),
                    const SizedBox(height: 15),
                    _fieldLabel('Location'),
                    BusinessPolicyField(
                      policy: _policy,
                      name: 'custom_address',
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: BusinessPolicyField(
                              policy: _policy,
                              name: 'custom_address',
                              child: TextFormField(
                                controller: _locationController,
                                maxLength: _policy.maxLength('custom_address'),
                                readOnly: _policy.readOnly('custom_address'),
                                textCapitalization: TextCapitalization.words,
                                decoration: _fieldDecoration(hint: 'Chennai'),
                                validator:
                                    (value) => _policy.validate(
                                      'custom_address',
                                      value,
                                      legacyRequired: true,
                                      requiredMessage:
                                          'Enter or get the location.',
                                    ),
                              ),
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
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
                    ),
                    const SizedBox(height: 15),
                    _fieldLabel('Requirement'),
                    BusinessPolicyField(
                      policy: _policy,
                      name: 'custom_requirement',
                      child: TextFormField(
                        controller: _requirementController,
                        maxLength: _policy.maxLength('custom_requirement'),
                        readOnly: _policy.readOnly('custom_requirement'),
                        minLines: 2,
                        maxLines: 3,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: _fieldDecoration(
                          hint: '200 KLD STP for residential project',
                        ),
                        validator:
                            (value) => _policy.validate(
                              'custom_requirement',
                              value,
                              legacyRequired: true,
                              requiredMessage: 'Enter the requirement.',
                            ),
                      ),
                    ),
                    // "Check for duplicates" was removed: the
                    // create_lead_from_mobile API has no duplicate-check
                    // option, so the checkbox never had any effect.
                    const SizedBox(height: 8),
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
