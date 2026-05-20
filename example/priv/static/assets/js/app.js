document.querySelectorAll("[role=alert][data-flash]").forEach((element) => {
  element.addEventListener("click", () => {
    element.setAttribute("hidden", "");
  });
});

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");

if (typeof LiveView !== "undefined" && typeof Phoenix !== "undefined" && csrfToken) {
  const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    params: {_csrf_token: csrfToken}
  });

  liveSocket.connect();
  window.liveSocket = liveSocket;
}
