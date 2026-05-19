import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_button.dart';
import '../data/auth_service.dart';
import '../providers/auth_providers.dart';

/// Login screen — email/password authentication backed by [AuthService].
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  AuthErrorKind? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final router = GoRouter.of(context);
    final outcome = await ref.read(authServiceProvider).signInWithEmail(
          email: _emailController.text,
          password: _passwordController.text,
        );
    if (!mounted) return;
    switch (outcome) {
      case AuthSuccess():
        router.go('/');
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
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 48),
              Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: AppColors.primaryLight,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.hearing,
                      size: 32, color: AppColors.primary),
                ),
              ),
              const SizedBox(height: 24),
              Center(child: Text('Welcome Back', style: AppTypography.h1)),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Sign in to Recycled Sound',
                  style: AppTypography.body.copyWith(color: AppColors.textMuted),
                ),
              ),
              const SizedBox(height: 40),
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
                onSubmitted: (_) => _signIn(),
                decoration: const InputDecoration(hintText: 'Enter password'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!.userMessage,
                  style: AppTypography.caption.copyWith(color: AppColors.error),
                ),
              ],
              const SizedBox(height: 32),
              RsButton(
                label: _submitting ? 'Signing in…' : 'Sign In',
                onPressed: _submitting ? null : _signIn,
              ),
              const SizedBox(height: 16),
              Center(
                child: TextButton(
                  onPressed:
                      _submitting ? null : () => context.push('/signup'),
                  child: Text.rich(
                    TextSpan(
                      text: "Don't have an account? ",
                      style: AppTypography.body,
                      children: [
                        TextSpan(
                          text: 'Sign Up',
                          style: AppTypography.button
                              .copyWith(color: AppColors.primary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
