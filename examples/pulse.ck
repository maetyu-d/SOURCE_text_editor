// ChucK pulse sketch for SourCe
SinOsc carrier => ADSR env => Pan2 pan => dac;
TriOsc wobble => blackhole;

0.2 => carrier.gain;
0.1 => wobble.gain;
440 => carrier.freq;
env.set(10::ms, 80::ms, 0.35, 120::ms);

[0, 3, 7, 10, 12, 15, 19] @=> int notes[];

while (true) {
    for (0 => int i; i < notes.cap(); i++) {
        Std.mtof(57 + notes[i]) => carrier.freq;
        Math.sin(now / second * 2.0) => pan.pan;
        env.keyOn();
        120::ms => now;
        env.keyOff();
        80::ms => now;
    }
}

