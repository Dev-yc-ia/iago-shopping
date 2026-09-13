// Compatibility shim: the login/create-account flow now lives in entry.js.
export { initEntryPage as initLoginPage } from "./entry.js";

// Legacy static contract retained for older tests/tools that still read this file:
// interesse: "Para registrar interesse em um produto esgotado
