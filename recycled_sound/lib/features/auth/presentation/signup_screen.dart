import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_button.dart';
import '../data/auth_service.dart';
import '../data/models/user_profile.dart';
import '../providers/auth_providers.dart';

/// Signup screen — new user registration with role selection.
///
/// Self-assignable roles are donor/recipient only; audiologist + admin are
/// granted by an existing admin via a follow-up write to `users/{uid}.role`
/// (gated by the firestore rules).
class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  UserRole _selectedRole = UserRole.donor;
  bool _submitting = false;
  AuthErrorKind? _error;
  String? _validationError;

  /// Only self-assignable roles are shown.
  static const _roleOptions = <(UserRole, String, String)>[
    (UserRole.donor, 'Donor', 'Donate hearing aids to those in need'),
    (UserRole.recipient, 'Recipient', 'Apply for a donated hearing aid'),
  ];

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    if (_submitting) return;
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (name.isEmpty) {
      setState(() => _validationError = 'Please enter your name.');
      return;
    }
    if (password.length < 8) {
      setState(() => _validationError = 'Password must be at least 8 characters.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _validationError = null;
    });
    final router = GoRouter.of(context);
    final auth = ref.read(authServiceProvider);
    final repo = ref.read(userProfileRepositoryProvider);
    final outcome = await auth.signUpWithEmail(email: email, password: password);
    if (!mounted) return;
    switch (outcome) {
      case AuthSuccess(:final user):
        try {
          await repo.createOnSignup(
            UserProfile(
              uid: user.uid,
              email: email,
              displayName: name,
              role: _selectedRole,
            ),
          );
          if (!mounted) return;
          router.go('/');
        } catch (e) {
          setState(() {
            _submitting = false;
            _validationError = 'Account created but profile save failed: $e';
          });
        }
      case AuthFailure(:final kind):
        setState(() {
          _submitting = false;
          _error = kind;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Name', style: AppTypography.label),
              const SizedBox(height: 8),
              TextField(
                controller: _nameController,
                enabled: !_submitting,
                decoration: const InputDecoration(hintText: 'Full name'),
              ),
              const SizedBox(height: 20),
              Text('Email', style: AppTypography.label),
              const SizedBox(height: 8),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                enabled: !_submitting,
                decoration: const InputDecoration(hintText: 'you@example.com'),
              ),
              const SizedBox(height: 20),
              Text('Password', style: AppTypography.label),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: true,
                enabled: !_submitting,
                onSubmitted: (_) => _signUp(),
                decoration: const InputDecoration(hintText: 'Min 8 characters'),
              ),
              const SizedBox(height: 24),
              Text('I am a…', style: AppTypography.h4),
              const SizedBox(height: 12),
              ..._roleOptions.map((entry) {
                final (role, title, subtitle) = entry;
                final isSelected = _selectedRole == role;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GestureDetector(
                    onTap: _submitting
                        ? null
                        : () => setState(() => _selectedRole = role),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppColors.primaryLight
                            : AppColors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? AppColors.primary
                              : AppColors.border,
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isSelected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: isSelected
                                ? AppColors.primary
                                : AppColors.textMuted,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, style: AppTypography.h4),
                                Text(subtitle, style: AppTypography.caption),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
              if (_error != null || _validationError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _validationError ?? _error!.userMessage,
                  style: AppTypography.caption.copyWith(color: AppColors.error),
                ),
              ],
              const SizedBox(height: 24),
              RsButton(
                label: _submitting ? 'Creating…' : 'Create Account',
                onPressed: _submitting ? null : _signUp,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
