import { recordEvent } from "../utils/analytics.js";
import { signInWithGoogle, signInWithPassword } from "./auth.js";

export function initEntryPage() {
  document.querySelector("#home-access-form")?.addEventListener("submit", async (event) => {
    event.preventDefault();
    recordEvent("login_start", { source: "entry_form" });
    const access = document.querySelector("#home-access")?.value;
    const password = document.querySelector("#home-password")?.value;

    try {
      await signInWithPassword(access, password);
      window.location.href = "/catalogo/";
    } catch (error) {
      window.alert(error.message);
    }
  });

  document.querySelector("#continue-with-google")?.addEventListener("click", async () => {
    recordEvent("login_start", { source: "google_visual_entry" });
    try {
      await signInWithGoogle();
    } catch (error) {
      window.alert(error.message);
    }
  });

  document.querySelector("#continue-without-login")?.addEventListener("click", () => {
    recordEvent("continue_without_login", { source: "entry_page" });
  });
}
