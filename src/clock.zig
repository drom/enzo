// Clock generator: signal driver + 4 edge events.
//   posedge / negedge          - notified post-eval (sample, drive next-edge)
//   posedge_pre / negedge_pre  - notified pre-eval (drives stable for THIS edge)

pub fn Clock(comptime W: type) type {
    return struct {
        const Self = @This();

        wheel:       *W,
        signal:      *u8,
        half_period: u32,
        posedge:     W.Event,
        negedge:     W.Event,
        posedge_pre: W.Event,
        negedge_pre: W.Event,
        step:        u32,

        pub fn init(self: *Self, wheel: *W, signal: *u8, half_period: u32) void {
            self.wheel = wheel;
            self.signal = signal;
            self.half_period = half_period;
            self.posedge.init();
            self.negedge.init();
            self.posedge_pre.init();
            self.negedge_pre.init();
            self.step = 0;
        }

        pub fn run(self: *Self) void {
            switch (self.step) {
                0 => {
                    self.signal.* = 1;
                    _ = self.posedge_pre.notify(self.wheel);
                    _ = self.posedge.notifyPost(self.wheel);
                    self.step = 1;
                    _ = self.wheel.schedule(self.half_period, self);
                },
                1 => {
                    self.signal.* = 0;
                    _ = self.negedge_pre.notify(self.wheel);
                    _ = self.negedge.notifyPost(self.wheel);
                    self.step = 0;
                    _ = self.wheel.schedule(self.half_period, self);
                },
                else => {},
            }
        }

        pub fn start(self: *Self) bool {
            return self.wheel.schedule(0, self);
        }
    };
}
