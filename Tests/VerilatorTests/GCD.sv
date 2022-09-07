module GCD(
  input  [3:0] a,
               b,
  input        clock,
               loadValues,
  output [3:0] result,
  output       isValid);

  reg [3:0] x;
  reg [3:0] y;
  always @(posedge clock) begin
    if (loadValues) begin
      x <= a;
      y <= b;
    end
    else if (x > y)
      x <= x - y;
    else
      y <= y - x;
  end
  assign result = x;
  assign isValid = y == 4'h0;
endmodule
