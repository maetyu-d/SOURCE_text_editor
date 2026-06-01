// SuperCollider neon sketch for Source TEXT
(
SynthDef(\neonRipple, { |freq = 110, amp = 0.18, pan = 0|
    var pulse = Impulse.kr(6);
    var sweep = Demand.kr(pulse, 0, Dseq([0, 3, 7, 10, 12], inf));
    var tone = SinOsc.ar((freq * (sweep.midiratio)) * [1, 1.005]);
    var env = Decay2.kr(pulse, 0.01, 0.42);
    var shine = BPF.ar(WhiteNoise.ar(0.08), freq * 8, 0.18);
    Out.ar(0, Pan2.ar((tone + shine) * env * amp, pan));
}).add;
)

(
Pbind(
    \instrument, \neonRipple,
    \dur, Pseq([0.25, 0.25, 0.5, 0.125, 0.375], inf),
    \freq, Pseq([110, 146.83, 164.81, 220, 293.66], inf),
    \pan, Pwhite(-0.75, 0.75),
    \amp, 0.22
).play;
)

