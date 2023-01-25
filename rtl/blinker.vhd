library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

library xpm;
use xpm.vcomponents.all;

entity blinker is port (
	clk_100mhz : in std_logic;
	led : out std_logic := '0');
end blinker;

architecture behav of blinker is
	signal clk_50mhz : std_logic;

	signal inst_addr : std_logic_vector(11 downto 0);
	signal inst : std_logic_vector(15 downto 0);
	signal inst_regce : std_logic;

	signal addr, wdata : std_logic_vector(31 downto 0);
	signal rdata : std_logic_vector(31 downto 0) := (others => '0');
	signal wmask : std_logic_vector(3 downto 0);
	signal rreq : std_logic;
begin
	-- On 7-series FPGAs, we do not close timing at 100 MHz.
	clkbuf : bufr
	generic map (BUFR_DIVIDE => "2")
	port map (
		I => clk_100mhz,
		O => clk_50mhz,
		CE => '1',
		CLR => '0');

	rom : xpm_memory_tdpram
	generic map (
		ADDR_WIDTH_A => 11,
		ADDR_WIDTH_B => 10,
		AUTO_SLEEP_TIME => 0,
		BYTE_WRITE_WIDTH_A => 16,
		BYTE_WRITE_WIDTH_B => 32,
		CASCADE_HEIGHT => 0,
		CLOCKING_MODE => "common_clock",
		ECC_MODE => "no_ecc",
		MEMORY_INIT_FILE => "blink.mem",
		MEMORY_INIT_PARAM => "0",
		MEMORY_OPTIMIZATION => "true",
		MEMORY_PRIMITIVE => "block",
		MEMORY_SIZE => 32 * 1024,
		MESSAGE_CONTROL => 0,
		READ_DATA_WIDTH_A => 16,
		READ_DATA_WIDTH_B => 32,
		READ_LATENCY_A => 2,
		READ_LATENCY_B => 1,
		READ_RESET_VALUE_A => "0",
		READ_RESET_VALUE_B => "0",
		RST_MODE_A => "SYNC",
		RST_MODE_B => "SYNC",
		SIM_ASSERT_CHK => 0,
		USE_EMBEDDED_CONSTRAINT => 0,
		USE_MEM_INIT => 1,
		USE_MEM_INIT_MMI => 1,
		WAKEUP_TIME => "disable_sleep",
		WRITE_DATA_WIDTH_A => 16,
		WRITE_DATA_WIDTH_B => 32,
		WRITE_MODE_A => "no_change",
		WRITE_MODE_B => "no_change",
		WRITE_PROTECT => 1)
	port map (
		douta => inst,
		doutb => rdata,
		addra => inst_addr(inst_addr'high downto 1),
		addrb => addr(inst_addr'high downto 2),
		clka => clk_50mhz,
		clkb => clk_50mhz,
		dina => 16x"0",
		dinb => wdata,
		ena => '1',
		enb => rreq,
		injectdbiterra => '0',
		injectdbiterrb => '0',
		injectsbiterra => '0',
		injectsbiterrb => '0',
		regcea => inst_regce,
		regceb => '1',
		rsta => '0',
		rstb => '0',
		sleep => '0',
		wea => "0",
		web => "0");

	dut : entity work.minimax
	generic map (
		PC_BITS => inst_addr'length,
		UC_BASE => x"00000800",
		TRACE => False)
	port map (
		clk => clk_50mhz,
		reset => '0',
		inst_addr => inst_addr,
		inst => inst,
		inst_regce => inst_regce,
		addr => addr,
		wdata => wdata,
		rdata => rdata,
		wmask => wmask,
		rreq => rreq);

	-- Capture LED blinker
	io_proc: process(clk_50mhz)
	begin
		if rising_edge(clk_50mhz) then
			-- Writes to address 0xfffffffc address the LED
			if wmask=x"f" and addr=x"fffffffc" then
				led <= wdata(0);
			end if;
		end if;
	end process;
end behav;
