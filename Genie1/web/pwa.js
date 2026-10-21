/* Browser integrations for the existing Flutter screens. */
(() => {
  'use strict';
  if ('serviceWorker' in navigator && window.isSecureContext) {
    window.addEventListener('load', () => {
      navigator.serviceWorker.register(new URL('pwa-sw.js', document.baseURI), {scope: new URL('.', document.baseURI).pathname, updateViaCache: 'none'})
        .catch(error => console.warn('PWA registration failed:', error.name));
      const config = self.GENIE_WEB_CONFIG?.firebase;
      if (config) navigator.serviceWorker.register(new URL('push/firebase-messaging-sw.js', document.baseURI), {scope: new URL('push/', document.baseURI).pathname, updateViaCache: 'none'})
        .catch(error => console.warn('Web push registration failed:', error.name));
    });
  }
  // Maps JavaScript services work with browser key restrictions and CORS.
  const sessions = new Map();
  const predictions = new Map();
  let mapsPromise;
  const loadMaps = () => mapsPromise ??= new Promise((resolve, reject) => {
    if (self.google?.maps?.importLibrary) { resolve(); return; }
    const key = self.GENIE_WEB_CONFIG?.mapsApiKey;
    if (!key) { reject(new Error('Configure GOOGLE_MAPS_WEB_API_KEY.')); return; }
    const callback = '__genieMapsReady';
    self[callback] = () => { delete self[callback]; resolve(); };
    const script = document.createElement('script');
    script.src = `https://maps.googleapis.com/maps/api/js?key=${encodeURIComponent(key)}&loading=async&v=weekly&callback=${callback}`;
    script.onerror = () => reject(new Error('Maps could not load. Check your connection.'));
    document.head.appendChild(script);
  });
  // Start without delaying login. The Flutter map widget expects this SDK.
  loadMaps().catch(error => console.warn(error.message));
  self.genieMapCall = async (operation, input) => {
    await loadMaps();
    const args = JSON.parse(input);
    if (operation === 'suggest' || operation === 'place') {
      const places = await google.maps.importLibrary('places');
      if (!sessions.has(args.sessionToken)) {
        if (sessions.size >= 20) { const oldest = sessions.keys().next().value; sessions.delete(oldest); predictions.delete(oldest); }
        sessions.set(args.sessionToken, new places.AutocompleteSessionToken());
      }
      if (operation === 'suggest') {
        const {suggestions} = await places.AutocompleteSuggestion.fetchAutocompleteSuggestions({input: args.query, sessionToken: sessions.get(args.sessionToken), region: 'in', locationBias: {center: {lat: args.lat, lng: args.lng}, radius: 50000}});
        predictions.set(args.sessionToken, suggestions.filter(s => s.placePrediction).map(s => s.placePrediction));
        return JSON.stringify({results: suggestions.filter(s => s.placePrediction).slice(0, 5).map(s => ({placeId: s.placePrediction.placeId, address: s.placePrediction.text.toString()}))});
      }
      const prediction = predictions.get(args.sessionToken)?.find(p => p.placeId === args.placeId);
      const place = prediction ? prediction.toPlace() : new places.Place({id: args.placeId});
      await place.fetchFields({fields: ['location']});
      sessions.delete(args.sessionToken);
      predictions.delete(args.sessionToken);
      if (!place.location) throw new Error('Google Maps returned no coordinates.');
      return JSON.stringify({lat: place.location.lat(), lng: place.location.lng()});
    }
    const {Geocoder} = await google.maps.importLibrary('geocoding');
    const query = operation === 'reverse' ? {location: {lat: args.lat, lng: args.lng}} : args.placeId ? {placeId: args.placeId} : {address: args.address, region: 'in'};
    const {results} = await new Geocoder().geocode(query);
    if (!results?.length) {
      if (operation === 'search') return JSON.stringify({results: []});
      throw new Error('No location found.');
    }
    const rows = results.slice(0, 5).map(row => ({address: row.formatted_address, lat: row.geometry.location.lat(), lng: row.geometry.location.lng()}));
    return JSON.stringify(operation === 'search' ? {results: rows} : rows[0]);
  };
})();
