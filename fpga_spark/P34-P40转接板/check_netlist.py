import re

netlist_path = r"C:\Users\gjl50\Desktop\FPGA\fpga_spark\P34-P40转接板\Netlist_Schematic1_2026-10-24.tel"
with open(netlist_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

in_nets = False
nets = {}
for line in lines:
    line = line.strip()
    if line == "$NETS":
        in_nets = True
        continue
    if line == "$SCHEDULE" or line == "$END":
        in_nets = False
        continue
    if in_nets and ";" in line:
        parts = line.split(";")
        net = parts[0].strip().strip("'")
        pins = parts[1].strip().split()
        nets[net] = pins

print(f"Total nets parsed: {len(nets)}")

# Standard reference:
# J2 is 34P LCD screen header (P1)
# U2 is 40P FPGA J13 connector
# Let's map each J2 pin to U2 pin and check!
j2_to_net = {}
u2_to_net = {}
for net, pins in nets.items():
    for p in pins:
        if p.startswith("J2."):
            pin_num = int(p.split(".")[1])
            j2_to_net[pin_num] = net
        elif p.startswith("U2."):
            pin_num = int(p.split(".")[1])
            u2_to_net[pin_num] = net

print("\n--- J2 (34P Screen Header) Pinout & Net ---")
for p in range(1, 35):
    print(f"J2.{p:2d}: {j2_to_net.get(p, 'UNCONNECTED')}")

print("\n--- U2 (40P FPGA J13 Header) Pinout & Net ---")
for p in range(1, 41):
    print(f"U2.{p:2d}: {u2_to_net.get(p, 'UNCONNECTED')}")
