export const environment = {
    production: false,
    mapTitle: window['env']['mapTitle'] ||
          'POI Map Visualizer (Backstage Workshop RH Summit 23 Edition)',
    mapAttribution: window['env']['mapAttribution'] || 
          'Map data &copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    mapUrl: window['env']['mapUrl'] || 
          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    mapToken: window['env']['mapToken'] || 
          '',
    gatewayApiUrl: window['env']['gatewayApiUrl'] || 
          'http://localhost:8082',
    websocketEndpoint: window['env']['websocketEndpoint'] || 
          'ws://localhost:8082/ws-server-endpoint'
  };
  