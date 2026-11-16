/*
 * AudioWorklet host for the practice playback renderer (audio-render.js).
 * The renderer runs on the audio thread so Flutter frames or recognition on
 * the main thread cannot starve it; audio.js talks to it through the port.
 */
import { Player } from './audio-render.js';

class ChoirPlaybackProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.player = new Player(sampleRate, (message) => this.port.postMessage(message));
    this.port.onmessage = (event) => this.player.handle(event.data);
  }

  process(inputs, outputs) {
    const output = outputs[0];
    if (!output || output.length === 0) return true;
    this.player.process(output[0], currentTime);
    for (let c = 1; c < output.length; c++) output[c].set(output[0]);
    return true;
  }
}

registerProcessor('choir-playback', ChoirPlaybackProcessor);
