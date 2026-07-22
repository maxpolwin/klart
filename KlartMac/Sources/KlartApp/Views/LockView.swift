#if os(macOS)
import SwiftUI
import KlartKit

/// Full-window lock screen shown while the vault is locked. Nothing behind
/// it is in memory — unlocking derives the key and only then loads notes.
struct LockView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var password = ""
    @State private var unlocking = false
    @State private var failed = false
    @State private var shakeOffset: CGFloat = 0
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.75))
                .symbolEffect(.bounce, value: failed)

            Text("Notes are locked")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Your notes are encrypted on disk.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 8) {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .focused($passwordFocused)
                    .onSubmit { attemptPasswordUnlock() }
                    .disabled(unlocking)

                Button {
                    attemptPasswordUnlock()
                } label: {
                    if unlocking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Unlock")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(password.isEmpty || unlocking)
            }
            .offset(x: shakeOffset)
            .padding(.top, 6)

            if state.lockoutRemaining > 0 {
                Text("Too many attempts — try again in \(state.lockoutRemaining)s.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.color(for: .structure))
            } else if failed {
                Text("Wrong password.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.color(for: .question))
            }

            if state.biometricUnlockAvailable {
                Button {
                    Task { await attemptBiometricUnlock() }
                } label: {
                    Label("Unlock with Touch ID", systemImage: "touchid")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
                .disabled(unlocking)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onAppear {
            passwordFocused = true
            // Offer the fast path right away, like unlocking a Mac.
            if state.biometricUnlockAvailable {
                Task { await attemptBiometricUnlock() }
            }
        }
    }

    private func attemptPasswordUnlock() {
        guard !password.isEmpty, !unlocking else { return }
        unlocking = true
        failed = false
        let attempt = password
        Task {
            let success = await state.unlock(password: attempt)
            unlocking = false
            if success {
                password = ""
            } else {
                failed = true
                password = ""
                passwordFocused = true
                shake()
            }
        }
    }

    private func attemptBiometricUnlock() async {
        guard !unlocking else { return }
        unlocking = true
        _ = await state.unlockWithBiometrics()
        unlocking = false
    }

    private func shake() {
        guard !reduceMotion else { return }
        withAnimation(.spring(duration: 0.08)) { shakeOffset = -10 }
        withAnimation(.spring(duration: 0.3, bounce: 0.7).delay(0.08)) { shakeOffset = 0 }
    }
}
#endif
