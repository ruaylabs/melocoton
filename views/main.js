// The splash and sidecar have different origins; use the shared native preference.
if (window.__TAURI__) {
  const { invoke } = window.__TAURI__.core;
  let preference = localStorage.getItem("theme") || "system";
  try {
    preference = await invoke("saved_theme");
  } catch (error) {
    console.error(error);
  }
  const dark = preference === "dark" ||
    (preference === "system" && window.matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.setAttribute("data-theme", dark ? "dark" : "light");
  let revealed = false;
  const reveal = () => {
    if (revealed) return;
    revealed = true;
    invoke("theme_ready", { preference, dark }).catch(console.error);
  };
  requestAnimationFrame(() => requestAnimationFrame(reveal));
  // Hidden webviews may suspend animation frames; the theme is already applied.
  setTimeout(reveal, 100);
}
