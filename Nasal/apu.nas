var rotor_rpm = props.globals.getNode("engines/APU/main/rpm");
var torque = props.globals.getNode("engines/APU/gear/total-torque", 1);
var collective = 1;
var turbine = props.globals.getNode("engines/APU/turbine-rpm-pct", 1);
var torque_pct = props.globals.getNode("engines/APU/torque-pct", 1);
var target_rel_rpm = props.globals.getNode("controls/APU/reltarget", 1);
var max_rel_torque = props.globals.getNode("controls/APU/maxreltorque", 1);



var Engine = {
	new: func(n) {
		var m = { parents: [Engine] };
		m.in = props.globals.getNode("controls/engines", 1).getChild("engine", n, 1);
		m.out = props.globals.getNode("engines", 1).getChild("engine", n, 1);
		m.airtempN = props.globals.getNode("/environment/temperature-degc");

		# input
		m.ignitionN = m.in.initNode("ignition", 0, "BOOL");
		m.starterN = m.in.initNode("starter", 0, "BOOL");
		m.powerN = m.in.initNode("power", 0);
		m.magnetoN = m.in.initNode("magnetos", 1, "INT");

		# output
		m.runningN = m.out.initNode("running", 0, "BOOL");
		m.n1_pctN = m.out.initNode("n1-pct", 0);
		m.n2_pctN = m.out.initNode("n2-pct", 0);
		m.n1N = m.out.initNode("n1-rpm", 0);
		m.n2N = m.out.initNode("n2-rpm", 0);
		m.totN = m.out.initNode("tot-degc", m.airtempN.getValue());

		m.starterLP = aircraft.lowpass.new(3);
		m.n1LP = aircraft.lowpass.new(4);
		m.n2LP = aircraft.lowpass.new(4);
		setlistener("/sim/signals/reinit", func(n) n.getValue() or m.reset(), 1);
		m.timer = aircraft.timer.new("/sim/time/hobbs/turbines[" ~ n ~ "]", 10);
		m.running = 0;
		m.fuelflow = 0;
		m.n1 = -1;
		m.up = -1;
		return m;
	},
	reset: func {
		me.magnetoN.setIntValue(1);
		me.ignitionN.setBoolValue(0);
		me.starterN.setBoolValue(0);
		me.powerN.setDoubleValue(0);
		me.runningN.setBoolValue(me.running = 0);
		me.starterLP.set(0);
		me.n1LP.set(me.n1 = 0);
		me.n2LP.set(me.n2 = 0);
	},
	update: func(dt, trim = 0) {
		var starter = me.starterLP.filter(me.starterN.getValue() * 0.19);	# starter 15-20% N1max
		me.powerN.setValue(me.power = clamp(me.powerN.getValue()));
		var power = me.power * 0.97 + trim;					# 97% = N2% in flight position

		if (me.running)
			power += (1 - collective.getValue()) * 0.03;			# droop compensator
		if (power > 1.12)
			power = 1.12;							# overspeed restrictor

		me.fuelflow = 0;
		if (!me.running) {
			if (me.n1 > 0.05 and power > 0.05 and me.ignitionN.getValue()) {
				me.runningN.setBoolValue(me.running = 1);
				me.timer.start();
			}

		} elsif (power < 0.05 or !fuel.level()) {
			me.runningN.setBoolValue(me.running = 0);
			me.timer.stop();

		} else {
			me.fuelflow = power;
		}

		var lastn1 = me.n1;
		me.n1 = me.n1LP.filter(max(me.fuelflow, starter));
		me.n2 = me.n2LP.filter(me.n1);
		me.up = me.n1 - lastn1;

		# temperature
		if (me.fuelflow > me.pos.idle)
			var target = 440 + (779 - 440) * (0.03 + me.fuelflow - me.pos.idle) / (me.pos.flight - me.pos.idle);
		else
			var target = 440 * (0.03 + me.fuelflow) / me.pos.idle;

		if (me.n1 < 0.4 and me.fuelflow - me.n1 > 0.001) {
			target += (me.fuelflow - me.n1) * 7000;
			if (target > 980)
				target = 980;
		}

		var airtemp = me.airtempN.getValue();
		if (target < airtemp)
			target = airtemp;

		var decay = (me.up > 0 ? 10 : me.n1 > 0.02 ? 0.01 : 0.001) * dt;
		me.totN.setValue((me.totN.getValue() + decay * target) / (1 + decay));

		# constant 150 kg/h for now (both turbines)
		fuel.consume(75 * KG2GAL * me.fuelflow * dt / 3600);

		# derived gauge values
		me.n1_pctN.setDoubleValue(me.n1 * 100);
		me.n2_pctN.setDoubleValue(me.n2 * 100);
		me.n1N.setDoubleValue(me.n1 * 50970);
		me.n2N.setDoubleValue(me.n2 * 33290);
	},
	setpower: func(v) {
		var target = (int((me.power + 0.15) * 3) + v) / 3;
		var time = abs(me.power - target) * 4;
		interpolate(me.powerN, target, time);
	},
	adjust_power: func(delta, mode = 0) {
		if (delta) {
			var power = me.powerN.getValue();
			if (me.power_min == nil) {
				if (delta > 0) {
					if (power < me.pos.idle) {
						me.power_min = me.pos.cutoff;
						me.power_max = me.pos.idle;
					} else {
						me.power_min = me.pos.idle;
						me.power_max = me.pos.flight;
					}
				} else {
					if (power > me.pos.idle) {
						me.power_max = me.pos.flight;
						me.power_min = me.pos.idle;
					} else {
						me.power_max = me.pos.idle;
						me.power_min = me.pos.cutoff;
					}
				}
			}
			me.powerN.setValue(power = clamp(power + delta, me.power_min, me.power_max));
			return power;
		} elsif (mode) {
			me.power_min = me.power_max = nil;
		}
	},
	pos: { cutoff: 0, idle: 0.63, flight: 1 },
};



var engines = {
	init: func {
		me.engine = [Engine.new(0)];
		me.trimN = props.globals.initNode("/controls/engines/power-trim");
		me.balanceN = props.globals.initNode("/controls/engines/power-balance");
		me.commonrpmN = props.globals.initNode("/engines/engine/rpm");
	},
	reset: func {
		me.engine[3].reset();
	},
	update: func(dt) {
		# update engines
		var trim = me.trimN.getValue() * 0.1;
		var balance = me.balanceN.getValue() * 0.1;
		me.engine[3].update(dt, trim - balance);

		# set rotor
		var n2max = max(me.engine[3].n2);
		target_rel_rpm.setValue(n2max);
		max_rel_torque.setValue(n2max);

		me.commonrpmN.setValue(n2max * 33290); # attitude indicator needs pressure

	},
	quickstart: func { # development only
		me.engine[3].n1LP.set(1);
		me.engine[3].n2LP.set(1);
		procedure.step = 1;
		procedure.next();
	},
};
