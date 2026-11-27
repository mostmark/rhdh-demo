(function (window) {
  window["env"] = window["env"] || {};
  window["env"]["mapTitle"] = 'POI Map Visualizer (Backstage Workshop RH Summit 23 Edition)';
  window["env"]["mapAttribution"] =
    'Map data &copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors';
  window["env"]["mapUrl"] =
    "https://tile.openstreetmap.org/{z}/{x}/{y}.png";
  window["env"]["mapToken"] =
    "";
  window["env"]["gatewayApiUrl"] = "http://localhost:8082";
  window["env"]["websocketEndpoint"] =
    "ws://localhost:8082/ws-server-endpoint";
})(this);
