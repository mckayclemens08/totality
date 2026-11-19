import "./tokens.css";
import "./styles.css";

// The frame only. Sign-in is not connected yet: the password is never read, stored or sent from here.
// Connecting it, and approving a browser from the iPhone, is step 3 (issue 150) and needs its own review.

const THEMES = ["default", "blush", "sky", "sage", "lilac", "graphite"] as const;

function applyStoredTheme(): void {
  try {
    const saved = localStorage.getItem("totality.theme");
    if (saved && (THEMES as readonly string[]).includes(saved)) {
      document.documentElement.dataset.theme = saved;
    }
  } catch {
    // Storage can be blocked. The default theme is fine.
  }
}

function wireSignIn(): void {
  const form = document.getElementById("sign-in");
  const status = document.getElementById("status");
  if (!(form instanceof HTMLFormElement) || !status) return;
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    status.textContent = "Signing in to the website isn't switched on yet. Your iPhone app works as usual.";
  });
}

applyStoredTheme();
wireSignIn();
