RTL = rtl/gray_sync.v rtl/async_fifo.v
TB  = tb/tb_async_fifo.v
OUT = sim/async_fifo.vvp
VCD = sim/async_fifo.vcd

.PHONY: sim wave gtkwave clean

sim: $(OUT)
	vvp $(OUT)

$(OUT): $(RTL) $(TB)
	mkdir -p sim
	iverilog -g2012 -o $(OUT) $(RTL) $(TB)

wave: sim
	python3 docs/plot_waveform.py

gtkwave: sim
	gtkwave $(VCD) &

clean:
	rm -rf sim/*.vvp sim/*.vcd
