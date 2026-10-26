## char-picker — Unicode characters by name: arrows, maths, box drawing, Greek, currency, emoji, Nerd Font symbols
##
##   Insert a character…   (Ctrl+Alt+U)   a list of about 850 characters, each with its name — type a few letters of
##                         it ("arrow", "alpha", "euro", "check", "nf-fa-git") and Enter puts it at the cursor (over
##                         the selection, when there is one); the ones you used last are at the top
##   Insert a character by its code point…   U+2192, 2192, &#8594; or &#x2192;
##   Character under the cursor: name and code point   in the status line: U+XXXX, its name, its UTF-8 bytes
##                         (an emoji with its variation selector or skin tone: each code point of it)
##   vim                   g8 (normal mode): the character under the cursor, as above (not ga: the align plugin's)
##   settings              plugins.char-picker.recent — how many of the characters used last come first (8; 0: none),
##                         kept in the plugin's data folder
##
## The groups: arrows, maths, Greek, box drawing, blocks and shapes, currency, punctuation, spaces and invisible
## characters, marks and checks, keys (⌘ ⌥ ⇧ ⏎ …), symbols, Latin letters, common emoji, and Nerd Font symbols
## (Powerline, Font Awesome, a few logos — they show only in a Nerd Font). The names are Unicode's; emoji, keys and
## spaces have their everyday names too ("red heart", "tab key", "nbsp"). The table is in this file: a character not
## in it is still named for "under the cursor" by the block it is in (a CJK ideograph, private use …).
import nedplugin

requiresNed(">= 6.29")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("recent", 8, "Insert a character…: how many of the characters you used last are listed first (0: none)")

# the characters: "# group" lines, then "XXXX name | everyday name" (the group "-": only named, not in the list)
const Table = """
# arrows
2190 leftwards arrow | left arrow, <-
2191 upwards arrow
2192 rightwards arrow | right arrow, ->
2193 downwards arrow
2194 left right arrow | <->
2195 up down arrow
2196 north west arrow | home key
2197 north east arrow
2198 south east arrow | end key
2199 south west arrow
219A leftwards arrow with stroke
219B rightwards arrow with stroke
21A6 rightwards arrow from bar
21A9 leftwards arrow with hook
21AA rightwards arrow with hook
21B0 upwards arrow with tip leftwards
21B1 upwards arrow with tip rightwards
21B2 downwards arrow with tip leftwards
21B3 downwards arrow with tip rightwards
21B5 downwards arrow with corner leftwards
21BA anticlockwise open circle arrow
21BB clockwise open circle arrow
21C4 rightwards arrow over leftwards arrow
21C6 leftwards arrow over rightwards arrow
21C7 leftwards paired arrows
21C9 rightwards paired arrows
21D0 leftwards double arrow
21D1 upwards double arrow
21D2 rightwards double arrow | implies, =>
21D3 downwards double arrow
21D4 left right double arrow | iff, <=>
21D5 up down double arrow
21E4 leftwards arrow to bar
21E5 rightwards arrow to bar
21E6 leftwards white arrow
21E7 upwards white arrow | shift key
21E8 rightwards white arrow
21E9 downwards white arrow
2794 heavy wide-headed rightwards arrow
279C heavy round-tipped rightwards arrow
27A4 black rightwards arrowhead
2B05 leftwards black arrow | left arrow
2B06 upwards black arrow | up arrow
2B07 downwards black arrow | down arrow
27F5 long leftwards arrow
27F6 long rightwards arrow
27F7 long left right arrow
27F8 long leftwards double arrow
27F9 long rightwards double arrow
27FA long left right double arrow
2934 arrow pointing rightwards then curving upwards
2935 arrow pointing rightwards then curving downwards
21AB leftwards arrow with loop
21AC rightwards arrow with loop
# maths
00B1 plus-minus sign | plus-minus, +-
00D7 multiplication sign | times, multiply
00F7 division sign | divide
2212 minus sign | minus
2213 minus-or-plus sign
2260 not equal to | not equal, !=
2248 almost equal to | approx
2261 identical to
2262 not identical to
2264 less-than or equal to | less or equal, <=
2265 greater-than or equal to | greater or equal, >=
226A much less-than
226B much greater-than
221E infinity
221A square root
221B cube root
2211 n-ary summation | sum, sigma
220F n-ary product | product
222B integral
222C double integral
222E contour integral
2202 partial differential
2207 nabla
2206 increment
2200 for all
2203 there exists | exists
2204 there does not exist
2205 empty set
2208 element of | in, element of
2209 not an element of
220B contains as member
2229 intersection
222A union
2282 subset of
2283 superset of
2286 subset of or equal to
2287 superset of or equal to
2284 not a subset of
2227 logical and | and
2228 logical or | or
00AC not sign | not
22BB xor
2295 circled plus
2297 circled times
2299 circled dot operator
22A2 right tack
22A8 true
22A4 down tack
22A5 up tack
2234 therefore
2235 because
221D proportional to
2220 angle
22C5 dot operator | dot product
2218 ring operator | compose
2219 bullet operator
22EF midline horizontal ellipsis
2032 prime
2033 double prime
00B0 degree sign | degrees
2030 per mille sign
00BD vulgar fraction one half
00BC vulgar fraction one quarter
00BE vulgar fraction three quarters
2153 vulgar fraction one third
2154 vulgar fraction two thirds
215B vulgar fraction one eighth
00B9 superscript one
00B2 superscript two
00B3 superscript three
2070 superscript zero
2074 superscript four
207F superscript latin small letter n
2080 subscript zero
2081 subscript one
2082 subscript two
2115 double-struck capital n
2124 double-struck capital z
211A double-struck capital q
211D double-struck capital r
2102 double-struck capital c
2135 alef symbol
210F planck constant over two pi
2113 script small l
2245 approximately equal to
2243 asymptotically equal to
223C tilde operator
2254 colon equals
225F questioned equal to
27E8 mathematical left angle bracket | angle bracket left
27E9 mathematical right angle bracket | angle bracket right
230A left floor
230B right floor
2308 left ceiling
2309 right ceiling
2016 double vertical line
27E6 mathematical left white square bracket
27E7 mathematical right white square bracket
2223 divides
2225 parallel to
2226 not parallel to
2216 set minus
2217 asterisk operator
2201 complement
22C0 n-ary logical and
22C1 n-ary logical or
22C2 n-ary intersection
22C3 n-ary union
2A2F vector or cross product | cross product
00B5 micro sign
# Greek
0391 greek capital letter alpha
0392 greek capital letter beta
0393 greek capital letter gamma
0394 greek capital letter delta
0395 greek capital letter epsilon
0396 greek capital letter zeta
0397 greek capital letter eta
0398 greek capital letter theta
0399 greek capital letter iota
039A greek capital letter kappa
039B greek capital letter lamda
039C greek capital letter mu
039D greek capital letter nu
039E greek capital letter xi
039F greek capital letter omicron
03A0 greek capital letter pi
03A1 greek capital letter rho
03A3 greek capital letter sigma
03A4 greek capital letter tau
03A5 greek capital letter upsilon
03A6 greek capital letter phi
03A7 greek capital letter chi
03A8 greek capital letter psi
03A9 greek capital letter omega
03B1 greek small letter alpha
03B2 greek small letter beta
03B3 greek small letter gamma
03B4 greek small letter delta
03B5 greek small letter epsilon
03B6 greek small letter zeta
03B7 greek small letter eta
03B8 greek small letter theta
03B9 greek small letter iota
03BA greek small letter kappa
03BB greek small letter lamda
03BC greek small letter mu
03BD greek small letter nu
03BE greek small letter xi
03BF greek small letter omicron
03C0 greek small letter pi
03C1 greek small letter rho
03C2 greek small letter final sigma
03C3 greek small letter sigma
03C4 greek small letter tau
03C5 greek small letter upsilon
03C6 greek small letter phi
03C7 greek small letter chi
03C8 greek small letter psi
03C9 greek small letter omega
03D1 greek theta symbol
03D5 greek phi symbol
03F5 greek lunate epsilon symbol
03D6 greek pi symbol
# box drawing
2500 box drawings light horizontal
2502 box drawings light vertical
250C box drawings light down and right
2510 box drawings light down and left
2514 box drawings light up and right
2518 box drawings light up and left
251C box drawings light vertical and right
2524 box drawings light vertical and left
252C box drawings light down and horizontal
2534 box drawings light up and horizontal
253C box drawings light vertical and horizontal
2501 box drawings heavy horizontal
2503 box drawings heavy vertical
250F box drawings heavy down and right
2513 box drawings heavy down and left
2517 box drawings heavy up and right
251B box drawings heavy up and left
2523 box drawings heavy vertical and right
252B box drawings heavy vertical and left
2533 box drawings heavy down and horizontal
253B box drawings heavy up and horizontal
254B box drawings heavy vertical and horizontal
2550 box drawings double horizontal
2551 box drawings double vertical
2554 box drawings double down and right
2557 box drawings double down and left
255A box drawings double up and right
255D box drawings double up and left
2560 box drawings double vertical and right
2563 box drawings double vertical and left
2566 box drawings double down and horizontal
2569 box drawings double up and horizontal
256C box drawings double vertical and horizontal
256D box drawings light arc down and right
256E box drawings light arc down and left
256F box drawings light arc up and left
2570 box drawings light arc up and right
2504 box drawings light triple dash horizontal
2506 box drawings light triple dash vertical
2508 box drawings light quadruple dash horizontal
250A box drawings light quadruple dash vertical
254C box drawings light double dash horizontal
254E box drawings light double dash vertical
2571 box drawings light diagonal upper right to lower left
2572 box drawings light diagonal upper left to lower right
2573 box drawings light diagonal cross
2574 box drawings light left
2576 box drawings light right
2575 box drawings light up
2577 box drawings light down
# blocks and shapes
2588 full block
2593 dark shade
2592 medium shade
2591 light shade
2580 upper half block
2584 lower half block
258C left half block
2590 right half block
2581 lower one eighth block
2582 lower one quarter block
2583 lower three eighths block
2585 lower five eighths block
2586 lower three quarters block
2587 lower seven eighths block
25A0 black square
25A1 white square
25AA black small square
25AB white small square
25B2 black up-pointing triangle
25B3 white up-pointing triangle
25B6 black right-pointing triangle
25B7 white right-pointing triangle
25BC black down-pointing triangle
25BD white down-pointing triangle
25C0 black left-pointing triangle
25C1 white left-pointing triangle
25B4 black up-pointing small triangle
25B8 black right-pointing small triangle
25BE black down-pointing small triangle
25C2 black left-pointing small triangle
25C6 black diamond
25C7 white diamond
25CB white circle
25CF black circle
25CE bullseye
25C9 fisheye
25D0 circle with left half black
25D1 circle with right half black
25E6 white bullet
2605 black star
2606 white star
2B1B black large square
2B1C white large square
25AC black rectangle
2B24 black large circle
2B58 heavy circle
# currency
0024 dollar sign
00A2 cent sign
00A3 pound sign | pound, sterling
00A5 yen sign | yen, yuan
20AC euro sign | euro
20B9 indian rupee sign | rupee
20BD ruble sign | rouble
20A9 won sign | won
20BA turkish lira sign | lira
20AA new sheqel sign | shekel
20A6 naira sign | naira
0E3F thai currency symbol baht | baht
20B1 peso sign | peso
20B4 hryvnia sign | hryvnia
20AB dong sign | dong
20A1 colon sign
20B5 cedi sign
20BF bitcoin sign | bitcoin
00A4 currency sign
20A3 french franc sign
20A8 rupee sign
FDFC rial sign | riyal, rial
20B8 tenge sign
20BC manat sign
20BE lari sign
20AD kip sign
20AE tugrik sign
20B2 guarani sign
20B3 austral sign
20B6 livre tournois sign
20B7 spesmilo sign
20BB nordic mark sign
20C0 som sign | som
# punctuation
2014 em dash
2013 en dash
2012 figure dash
2015 horizontal bar
2010 hyphen
2011 non-breaking hyphen
2026 horizontal ellipsis | ellipsis, dots
00B7 middle dot | middle dot, interpunct
2022 bullet | bullet point
2023 triangular bullet
2043 hyphen bullet
203B reference mark
00A7 section sign
00B6 pilcrow sign
2020 dagger
2021 double dagger
2018 left single quotation mark | single quote left
2019 right single quotation mark | single quote right, apostrophe
201C left double quotation mark | double quote left
201D right double quotation mark | double quote right
201A single low-9 quotation mark
201E double low-9 quotation mark
00AB left-pointing double angle quotation mark | guillemet, French quotes
00BB right-pointing double angle quotation mark | guillemet, French quotes
2039 single left-pointing angle quotation mark
203A single right-pointing angle quotation mark
300C left corner bracket
300D right corner bracket
00A9 copyright sign | (c)
00AE registered sign | (r)
2122 trade mark sign | TM
2116 numero sign
2117 sound recording copyright
203D interrobang
00BF inverted question mark
00A1 inverted exclamation mark
2042 asterism
2E2E reversed question mark
2031 per ten thousand sign
00AA feminine ordinal indicator
00BA masculine ordinal indicator
2044 fraction slash
# spaces and invisible
00A0 no-break space | nbsp
2009 thin space
200A hair space
2002 en space
2003 em space
2007 figure space
202F narrow no-break space | narrow nbsp
200B zero width space | zwsp
200C zero width non-joiner | zwnj
200D zero width joiner | zwj, joins emoji
2060 word joiner
FEFF zero width no-break space | BOM, byte order mark
00AD soft hyphen | shy
200E left-to-right mark | LRM
200F right-to-left mark | RLM
# marks and checks
2713 check mark | tick
2714 heavy check mark | tick
2717 ballot x | cross
2718 heavy ballot x | cross
2610 ballot box | check box, to do
2611 ballot box with check | check box done
2612 ballot box with x | check box crossed
2715 multiplication x
2716 heavy multiplication x
271A heavy greek cross
2731 heavy asterisk
2733 eight spoked asterisk
2734 eight pointed black star
2736 six pointed black star
273F black florette
2740 white florette
2766 floral heart
2767 rotated floral heart bullet
261B black right pointing index
261E white right pointing index
2690 white flag
2691 black flag
# keys
2318 place of interest sign | command key, cmd
2325 option key | option key, alt
2303 up arrowhead | control key, ctrl
238B broken circle with northwest arrow | escape key, esc
232B erase to the left | backspace key
2326 erase to the right | delete key
23CE return symbol | return key, enter
21B9 leftwards arrow to bar over rightwards arrow to bar | tab key
21EA upwards white arrow from bar | caps lock key
2423 open box | space key, visible space
2324 up arrowhead between two horizontal bars | enter key (up arrowhead between bars)
2387 alternative key symbol | alternative key
21DE upwards arrow with double stroke | page up key
21DF downwards arrow with double stroke | page down key
23CF eject symbol | eject
# symbols
2600 black sun with rays | sun
2601 cloud
2602 umbrella
2603 snowman
2604 comet
263A white smiling face
2639 white frowning face
2660 black spade suit
2663 black club suit
2665 black heart suit
2666 black diamond suit
2664 white spade suit
2667 white club suit
2661 white heart suit
2662 white diamond suit
266A eighth note
266B beamed eighth notes
266C beamed sixteenth notes
266D music flat sign
266E music natural sign
266F music sharp sign
2622 radioactive sign
2623 biohazard sign
262F yin yang
262E peace symbol
2618 shamrock
269B atom symbol
2696 scales
2692 hammer and pick
2702 black scissors
2709 envelope
270E lower right pencil
270F pencil
2712 black nib
2744 snowflake
2103 degree celsius
2109 degree fahrenheit
2126 ohm sign
212B angstrom sign
2640 female sign
2642 male sign
267B black universal recycling symbol | recycle
267E permanent paper sign
2693 anchor
2694 crossed swords
2695 staff of aesculapius
269C fleur-de-lis
26A1 high voltage sign | lightning, zap
2620 skull and crossbones
2672 universal recycling symbol
2668 hot springs
231A watch
231B hourglass | hourglass done
23F0 alarm clock
23F3 hourglass with flowing sand | hourglass, waiting
260E black telephone
2615 hot beverage | coffee
2638 wheel of dharma
262A star and crescent
2721 star of david
271D latin cross
2626 orthodox cross
2460 circled digit one
2461 circled digit two
2462 circled digit three
2463 circled digit four
2464 circled digit five
2465 circled digit six
2466 circled digit seven
2467 circled digit eight
2468 circled digit nine
2469 circled number ten
2776 dingbat negative circled digit one
2777 dingbat negative circled digit two
2778 dingbat negative circled digit three
2779 dingbat negative circled digit four
277A dingbat negative circled digit five
277B dingbat negative circled digit six
277C dingbat negative circled digit seven
277D dingbat negative circled digit eight
277E dingbat negative circled digit nine
277F dingbat negative circled number ten
2160 roman numeral one
2161 roman numeral two
2162 roman numeral three
2163 roman numeral four
2164 roman numeral five
2165 roman numeral six
2166 roman numeral seven
2167 roman numeral eight
2168 roman numeral nine
2169 roman numeral ten
# Latin letters
00C0 latin capital letter a with grave
00C1 latin capital letter a with acute
00C2 latin capital letter a with circumflex
00C3 latin capital letter a with tilde
00C4 latin capital letter a with diaeresis
00C5 latin capital letter a with ring above
00C6 latin capital letter ae
00C7 latin capital letter c with cedilla
00C8 latin capital letter e with grave
00C9 latin capital letter e with acute
00CA latin capital letter e with circumflex
00CB latin capital letter e with diaeresis
00CC latin capital letter i with grave
00CD latin capital letter i with acute
00CE latin capital letter i with circumflex
00CF latin capital letter i with diaeresis
00D0 latin capital letter eth
00D1 latin capital letter n with tilde
00D2 latin capital letter o with grave
00D3 latin capital letter o with acute
00D4 latin capital letter o with circumflex
00D5 latin capital letter o with tilde
00D6 latin capital letter o with diaeresis
00D8 latin capital letter o with stroke
00D9 latin capital letter u with grave
00DA latin capital letter u with acute
00DB latin capital letter u with circumflex
00DC latin capital letter u with diaeresis
00DD latin capital letter y with acute
00DE latin capital letter thorn
00DF latin small letter sharp s
00E0 latin small letter a with grave
00E1 latin small letter a with acute
00E2 latin small letter a with circumflex
00E3 latin small letter a with tilde
00E4 latin small letter a with diaeresis
00E5 latin small letter a with ring above
00E6 latin small letter ae
00E7 latin small letter c with cedilla
00E8 latin small letter e with grave
00E9 latin small letter e with acute
00EA latin small letter e with circumflex
00EB latin small letter e with diaeresis
00EC latin small letter i with grave
00ED latin small letter i with acute
00EE latin small letter i with circumflex
00EF latin small letter i with diaeresis
00F0 latin small letter eth
00F1 latin small letter n with tilde
00F2 latin small letter o with grave
00F3 latin small letter o with acute
00F4 latin small letter o with circumflex
00F5 latin small letter o with tilde
00F6 latin small letter o with diaeresis
00F8 latin small letter o with stroke
00F9 latin small letter u with grave
00FA latin small letter u with acute
00FB latin small letter u with circumflex
00FC latin small letter u with diaeresis
00FD latin small letter y with acute
00FE latin small letter thorn
00FF latin small letter y with diaeresis
0152 latin capital ligature oe
0153 latin small ligature oe
0141 latin capital letter l with stroke
0142 latin small letter l with stroke
0131 latin small letter dotless i
0130 latin capital letter i with dot above
015E latin capital letter s with cedilla
015F latin small letter s with cedilla
011E latin capital letter g with breve
011F latin small letter g with breve
010C latin capital letter c with caron
010D latin small letter c with caron
0160 latin capital letter s with caron
0161 latin small letter s with caron
017D latin capital letter z with caron
017E latin small letter z with caron
0158 latin capital letter r with caron
0159 latin small letter r with caron
0150 latin capital letter o with double acute
0151 latin small letter o with double acute
0170 latin capital letter u with double acute
0171 latin small letter u with double acute
0100 latin capital letter a with macron
0101 latin small letter a with macron
0112 latin capital letter e with macron
0113 latin small letter e with macron
012A latin capital letter i with macron
012B latin small letter i with macron
014C latin capital letter o with macron
014D latin small letter o with macron
016A latin capital letter u with macron
016B latin small letter u with macron
1E9E latin capital letter sharp s
0259 latin small letter schwa
014B latin small letter eng
# emoji
1F600 grinning face | smile
1F602 face with tears of joy | joy, laughing
1F642 slightly smiling face
1F609 winking face
1F60D smiling face with heart-shaped eyes | heart eyes
1F914 thinking face
1F605 smiling face with open mouth and cold sweat | sweat smile
1F60E smiling face with sunglasses
1F622 crying face | sad, tear
1F62D loudly crying face
1F621 pouting face
1F634 sleeping face
1F643 upside-down face
1F92F shocked face with exploding head | mind blown
1F973 face with party horn and party hat | party face
1F631 face screaming in fear | scream
1F644 face with rolling eyes | eye roll
1F610 neutral face
1F60A smiling face with smiling eyes | blush, smiling eyes
1F618 face throwing a kiss | kiss
1F923 rolling on the floor laughing | rofl, rolling on the floor laughing
1F970 smiling face with smiling eyes and three hearts | smiling face with hearts
1F44D thumbs up sign | thumbs up
1F44E thumbs down sign | thumbs down
1F44F clapping hands sign
1F64F person with folded hands | pray, thank you
1F4AA flexed biceps | strong, muscle
1F440 eyes
1F44B waving hand sign | wave, hello
270C victory hand
1F44C ok hand sign | OK
1F449 white right pointing backhand index | point right
1F446 white up pointing backhand index | point up
1F91D handshake
2764 heavy black heart | red heart
1F494 broken heart
1F499 blue heart
1F49A green heart
1F49B yellow heart
1F49C purple heart
1F525 fire
2728 sparkles | sparkles, new
2B50 white medium star | star
1F31F glowing star
1F389 party popper
1F38A confetti ball
1F381 wrapped present | gift, present
1F680 rocket
2705 white heavy check mark | check mark button, done
274C cross mark | cross, wrong
26A0 warning sign | warning
2757 heavy exclamation mark symbol | exclamation mark
2753 black question mark ornament | question mark
1F4A1 electric light bulb | idea, light bulb
1F41B bug
1F4DD memo
1F4CC pushpin
1F4CE paperclip
1F512 lock | locked
1F513 open lock | unlocked
1F511 key
1F527 wrench
1F528 hammer
2699 gear | gear, settings
1F4E6 package
1F4C1 file folder | folder
1F4C2 open file folder | open folder
1F4C4 page facing up | document, page
1F4C5 calendar
1F4BB personal computer | laptop
1F5A5 desktop computer
2328 keyboard
1F4F1 mobile phone
1F50D left-pointing magnifying glass | search, magnifying glass
1F517 link symbol
1F4C8 chart with upwards trend | chart up
1F4C9 chart with downwards trend | chart down
1F4CA bar chart
1F4AC speech balloon
1F4E3 cheering megaphone | megaphone
1F514 bell
1F3C1 chequered flag
1F6A7 construction sign | work in progress
1F3AF direct hit | target, bullseye
1F9EA test tube
1F9F9 broom
1F30D earth globe europe-africa | globe, earth
1F355 slice of pizza | pizza
1F382 birthday cake
1F319 crescent moon
1F308 rainbow
1F40D snake
1F980 crab
1F433 spouting whale
1F427 penguin
1F451 crown
1F4AF hundred points symbol | 100
1F195 squared new | new
1F534 large red circle
1F535 large blue circle
1F7E2 large green circle
1F7E1 large yellow circle
1F7E0 large orange circle | orange circle
1F7E3 large purple circle | purple circle
26AA medium white circle
26AB medium black circle
1F4A5 collision symbol | boom, collision
1F4A4 sleeping symbol | zzz, sleep
1F4A9 pile of poo | poo
1F47B ghost
1F916 robot face | robot
1F47D extraterrestrial alien | alien
1F648 see-no-evil monkey | see no evil
1F4F7 camera
1F3B5 musical note | music note
1F3AE video game | game controller
1F4DA books
1F4D6 open book
1F4BE floppy disk | floppy disk, save
1F4BF optical disc | CD
1F5D1 wastebasket | trash can, bin
1F6E0 hammer and wrench | tools
1F9E9 jigsaw puzzle piece | puzzle piece
1F9F0 toolbox
1F6AB no entry sign | prohibited, forbidden
26D4 no entry
1F4E7 e-mail symbol | email
1F4E2 public address loudspeaker | loudspeaker, announcement
1F3C6 trophy
1F947 first place medal | gold medal, first
1F340 four leaf clover
1F331 seedling
1F332 evergreen tree | evergreen tree, fir
1F334 palm tree
1F335 cactus
1F33B sunflower
1F339 rose
1F34E red apple | apple
1F34B lemon
1F36A cookie
1F37A beer mug | beer
1F377 wine glass | wine
1F697 automobile | car
2708 airplane | aeroplane, plane
1F6B2 bicycle
1F3E0 house building | house, home
1F3E2 office building | office
1F30A water wave | wave, sea
26C4 snowman without snow | snowman
1F321 thermometer
2614 umbrella with rain drops | umbrella, rain
1F4B0 money bag
1F4B3 credit card
1F4B8 money with wings
1F48E gem stone | gem, diamond
1F48C love letter
1F570 mantelpiece clock | clock
# Nerd Font
E0A0 nf-pl-branch | Powerline: version control branch
E0A1 nf-pl-line_number | Powerline: line number
E0A2 nf-pl-hostname | Powerline: padlock
E0B0 nf-pl-left_hard_divider | Powerline: solid triangle pointing right
E0B1 nf-pl-left_soft_divider | Powerline: angle pointing right
E0B2 nf-pl-right_hard_divider | Powerline: solid triangle pointing left
E0B3 nf-pl-right_soft_divider | Powerline: angle pointing left
E0B4 nf-ple-right_half_circle_thick | Powerline: solid half circle, round on the right
E0B5 nf-ple-right_half_circle_thin | Powerline: thin half circle, round on the right
E0B6 nf-ple-left_half_circle_thick | Powerline: solid half circle, round on the left
E0B7 nf-ple-left_half_circle_thin | Powerline: thin half circle, round on the left
E0B8 nf-ple-lower_left_triangle | Powerline: lower left triangle
E0BA nf-ple-lower_right_triangle | Powerline: lower right triangle
E0BC nf-ple-upper_left_triangle | Powerline: upper left triangle
E0BE nf-ple-upper_right_triangle | Powerline: upper right triangle
F002 nf-fa-search | magnifying glass
F004 nf-fa-heart | heart
F005 nf-fa-star | star
F007 nf-fa-user | user
F00C nf-fa-check | check mark
F00D nf-fa-close | cross (times)
F011 nf-fa-power_off | power
F013 nf-fa-cog | gear, settings
F014 nf-fa-trash_o | bin
F015 nf-fa-home | house
F016 nf-fa-file_o | file
F017 nf-fa-clock_o | clock
F019 nf-fa-download | download
F021 nf-fa-refresh | refresh
F023 nf-fa-lock | padlock
F024 nf-fa-flag | flag
F02B nf-fa-tag | tag
F02E nf-fa-bookmark | bookmark
F040 nf-fa-pencil | pencil
F04B nf-fa-play | play
F04C nf-fa-pause | pause
F04D nf-fa-stop | stop
F059 nf-fa-question_circle | question mark in a circle
F05A nf-fa-info_circle | information
F067 nf-fa-plus | plus
F068 nf-fa-minus | minus
F071 nf-fa-warning | warning triangle
F073 nf-fa-calendar | calendar
F07B nf-fa-folder | folder
F07C nf-fa-folder_open | open folder
F085 nf-fa-cogs | gears
F09B nf-fa-github | GitHub
F09C nf-fa-unlock | open padlock
F0AC nf-fa-globe | globe
F0C1 nf-fa-link | link
F0C5 nf-fa-files_o | copy
F0C7 nf-fa-floppy_o | save
F0E0 nf-fa-envelope | envelope
F0E7 nf-fa-bolt | lightning
F0EA nf-fa-clipboard | clipboard
F0EB nf-fa-lightbulb_o | light bulb
F0F3 nf-fa-bell | bell
F120 nf-fa-terminal | terminal
F121 nf-fa-code | code
F126 nf-fa-code_fork | fork
F15B nf-fa-file | file
F179 nf-fa-apple | Apple
F17A nf-fa-windows | Windows
F17B nf-fa-android | Android
F17C nf-fa-linux | Linux (Tux)
F188 nf-fa-bug | bug
F1C0 nf-fa-database | database
F1D3 nf-fa-git | Git
F1EB nf-fa-wifi | wifi
F1F8 nf-fa-trash | bin
F240 nf-fa-battery_full | battery
F418 nf-oct-git_branch | Git branch
F31A nf-linux-tux | Tux
F31B nf-linux-ubuntu | Ubuntu
F303 nf-linux-archlinux | Arch Linux
F306 nf-linux-debian | Debian
F30A nf-linux-fedora | Fedora
F01A5 nf-md-crown | crown (Nim's, in starship)
# -
0020 space
0021 exclamation mark
0022 quotation mark
0023 number sign
0025 percent sign
0026 ampersand
0027 apostrophe
0028 left parenthesis
0029 right parenthesis
002A asterisk
002B plus sign
002C comma
002D hyphen-minus
002E full stop
002F solidus
0030 digit zero
0031 digit one
0032 digit two
0033 digit three
0034 digit four
0035 digit five
0036 digit six
0037 digit seven
0038 digit eight
0039 digit nine
003A colon
003B semicolon
003C less-than sign
003D equals sign
003E greater-than sign
003F question mark
0040 commercial at
0041 latin capital letter a
0042 latin capital letter b
0043 latin capital letter c
0044 latin capital letter d
0045 latin capital letter e
0046 latin capital letter f
0047 latin capital letter g
0048 latin capital letter h
0049 latin capital letter i
004A latin capital letter j
004B latin capital letter k
004C latin capital letter l
004D latin capital letter m
004E latin capital letter n
004F latin capital letter o
0050 latin capital letter p
0051 latin capital letter q
0052 latin capital letter r
0053 latin capital letter s
0054 latin capital letter t
0055 latin capital letter u
0056 latin capital letter v
0057 latin capital letter w
0058 latin capital letter x
0059 latin capital letter y
005A latin capital letter z
005B left square bracket
005C reverse solidus
005D right square bracket
005E circumflex accent
005F low line
0060 grave accent
0061 latin small letter a
0062 latin small letter b
0063 latin small letter c
0064 latin small letter d
0065 latin small letter e
0066 latin small letter f
0067 latin small letter g
0068 latin small letter h
0069 latin small letter i
006A latin small letter j
006B latin small letter k
006C latin small letter l
006D latin small letter m
006E latin small letter n
006F latin small letter o
0070 latin small letter p
0071 latin small letter q
0072 latin small letter r
0073 latin small letter s
0074 latin small letter t
0075 latin small letter u
0076 latin small letter v
0077 latin small letter w
0078 latin small letter x
0079 latin small letter y
007A latin small letter z
007B left curly bracket
007C vertical line
007D right curly bracket
007E tilde
00A6 broken bar
00A8 diaeresis
00AF macron
00B4 acute accent
00B8 cedilla
0000 null
0007 bell
0008 backspace
0009 character tabulation (tab)
000A line feed
000B line tabulation
000C form feed
000D carriage return
001B escape
007F delete
"""

type Ch = object
  cp: int
  name, alias, group: string

var chars: seq[Ch]

proc load() =
  ## the table, read once
  if chars.len > 0: return
  var group = ""
  for l in Table.splitLines:
    if l.len == 0: continue
    if l.startsWith("# "):
      group = l[2 .. ^1]
      continue
    let sp = l.find(' ')
    if sp < 0: continue
    var name = l[sp + 1 .. ^1]
    var alias = ""
    let bar = name.find(" | ")
    if bar >= 0:
      alias = name[bar + 3 .. ^1]
      name = name[0 ..< bar]
    chars.add Ch(cp: parseHexInt(l[0 ..< sp]), name: name, alias: alias, group: group)

func utf8Of(cp: int): string =
  ## the code point as UTF-8
  if cp < 0x80: result.add char(cp)
  elif cp < 0x800:
    result.add char(0xC0 or (cp shr 6))
    result.add char(0x80 or (cp and 0x3F))
  elif cp < 0x10000:
    result.add char(0xE0 or (cp shr 12))
    result.add char(0x80 or ((cp shr 6) and 0x3F))
    result.add char(0x80 or (cp and 0x3F))
  else:
    result.add char(0xF0 or (cp shr 18))
    result.add char(0x80 or ((cp shr 12) and 0x3F))
    result.add char(0x80 or ((cp shr 6) and 0x3F))
    result.add char(0x80 or (cp and 0x3F))

func decodeAt(s: string, i: int): (int, int) =
  ## the code point that starts at byte i, and its length in bytes ((-1, 1): a byte that is not UTF-8)
  let b = ord(s[i])
  var n, cp: int
  if b < 0x80: return (b, 1)
  elif (b and 0xE0) == 0xC0: (n, cp) = (2, b and 0x1F)
  elif (b and 0xF0) == 0xE0: (n, cp) = (3, b and 0x0F)
  elif (b and 0xF8) == 0xF0: (n, cp) = (4, b and 0x07)
  else: return (-1, 1)
  if i + n > s.len: return (-1, 1)
  for k in 1 ..< n:
    let c = ord(s[i + k])
    if (c and 0xC0) != 0x80: return (-1, 1)
    cp = (cp shl 6) or (c and 0x3F)
  (cp, n)

func uplus(cp: int): string = "U+" & toHex(cp, (if cp > 0xFFFF: 5 else: 4))

func hexBytes(s: string): string =
  for i, c in s:
    if i > 0: result.add ' '
    result.add toHex(ord(c), 2)

func continues(cp: int): bool =
  ## a code point that belongs to the character before it: a combining mark, a variation selector, a skin tone,
  ## the joiner of an emoji sequence (and what comes after it)
  cp in 0x0300 .. 0x036F or cp in 0xFE00 .. 0xFE0F or cp in 0x1F3FB .. 0x1F3FF or cp == 0x200D or
    cp in 0x20D0 .. 0x20FF or cp in 0xE0020 .. 0xE007F

func blockOf(cp: int): string =
  ## what a code point not in the table is, by its block
  if cp < 0x20 or cp == 0x7F: "a control character"
  elif cp in 0x80 .. 0x9F: "a C1 control character"
  elif cp in 0x0100 .. 0x024F or cp in 0x1E00 .. 0x1EFF: "a Latin letter"
  elif cp in 0x0300 .. 0x036F: "a combining mark (it goes with the character before it)"
  elif cp in 0x0370 .. 0x03FF: "a Greek letter or sign"
  elif cp in 0x0400 .. 0x04FF: "a Cyrillic letter"
  elif cp in 0x0590 .. 0x05FF: "a Hebrew letter or sign"
  elif cp in 0x0600 .. 0x06FF or cp in 0x0750 .. 0x077F or cp in 0xFB50 .. 0xFDFF or cp in 0xFE70 .. 0xFEFF:
    "an Arabic letter or sign"
  elif cp in 0x0900 .. 0x097F: "a Devanagari letter or sign"
  elif cp in 0x0E00 .. 0x0E7F: "a Thai letter or sign"
  elif cp in 0x2000 .. 0x206F: "general punctuation"
  elif cp in 0x2070 .. 0x209F: "a superscript or subscript"
  elif cp in 0x20A0 .. 0x20CF: "a currency sign"
  elif cp in 0x2100 .. 0x214F: "a letter-like symbol"
  elif cp in 0x2190 .. 0x21FF or cp in 0x27F0 .. 0x27FF or cp in 0x2900 .. 0x297F: "an arrow"
  elif cp in 0x2200 .. 0x22FF or cp in 0x2A00 .. 0x2AFF: "a mathematical operator"
  elif cp in 0x2300 .. 0x23FF: "a technical symbol"
  elif cp in 0x2460 .. 0x24FF: "an enclosed letter or number"
  elif cp in 0x2500 .. 0x257F: "a box drawing character"
  elif cp in 0x2580 .. 0x259F: "a block element"
  elif cp in 0x25A0 .. 0x25FF: "a geometric shape"
  elif cp in 0x2600 .. 0x26FF: "a symbol"
  elif cp in 0x2700 .. 0x27BF: "a dingbat"
  elif cp in 0x2800 .. 0x28FF: "a braille pattern"
  elif cp in 0x3040 .. 0x309F: "a Hiragana letter"
  elif cp in 0x30A0 .. 0x30FF: "a Katakana letter"
  elif cp in 0x3400 .. 0x4DBF or cp in 0x4E00 .. 0x9FFF or cp in 0x20000 .. 0x323AF: "a CJK ideograph"
  elif cp in 0xAC00 .. 0xD7A3: "a Hangul syllable"
  elif cp in 0xE000 .. 0xF8FF or cp >= 0xF0000: "private use (an icon font, such as a Nerd Font, may draw it)"
  elif cp in 0xFE00 .. 0xFE0F: "a variation selector"
  elif cp in 0xFF00 .. 0xFFEF: "a full-width or half-width form"
  elif cp in 0x1F000 .. 0x1FAFF: "a pictograph (emoji)"
  else: "not in this plugin's table"

proc nameOf(cp: int): string =
  ## its name (Unicode's, or the Nerd Font's) — or what it is, by its block
  load()
  for c in chars:
    if c.cp == cp:
      return c.name & (if c.group == "Nerd Font": " (Nerd Font: " & c.alias & ")" else: "")
  if cp in 0xFE00 .. 0xFE0F: return "variation selector-" & $(cp - 0xFE00 + 1)
  if cp in 0x1F3FB .. 0x1F3FF:
    return "emoji modifier fitzpatrick type-" & (if cp == 0x1F3FB: "1-2" else: $(cp - 0x1F3FB + 2))
  if cp in 0x4E00 .. 0x9FFF or cp in 0x3400 .. 0x4DBF or cp in 0x20000 .. 0x323AF:
    return "cjk unified ideograph-" & toHex(cp, (if cp > 0xFFFF: 5 else: 4))
  "(" & blockOf(cp) & ")"

proc describe(line: string, col: int): string =
  ## the character at byte col of the line (at the end of the line: the one before), its code points, names, bytes
  if line.len == 0: return "The line is empty"
  var i = min(col, line.len - 1)
  while i > 0 and (ord(line[i]) and 0xC0) == 0x80: dec i       # (back to the first byte of the character)
  var (cp, n) = decodeAt(line, i)
  if cp < 0: return "A byte that is not UTF-8: 0x" & toHex(ord(line[i]), 2)
  var cps = @[cp]
  var e = i + n
  while e < line.len:                                          # (an emoji's selector, a skin tone, a joined emoji)
    let (c2, n2) = decodeAt(line, e)
    if c2 < 0 or not (continues(c2) or cps[^1] == 0x200D): break
    cps.add c2
    e += n2
  var codes, names: seq[string]
  for c in cps:
    codes.add uplus(c)
    names.add nameOf(c)
  let shown = if cp < 0x20 or cp == 0x7F: "" else: line[i ..< e] & "  "
  result = shown & codes.join(" ") & "  " & names.join(", ") & "  ·  UTF-8: " & hexBytes(line[i ..< e])
  if cps.len == 1: result.add "  ·  decimal " & $cp

func shown(c: Ch): string =
  ## what the list shows for a character: itself — or, for one that cannot be seen, a dotted square
  if c.group == "spaces and invisible" or c.cp < 0x20: "⬚" else: utf8Of(c.cp)

func label(c: Ch): string =
  shown(c) & "  " & c.name & (if c.alias.len > 0: " — " & c.alias else: "")

proc recents(): seq[int] =
  for x in readData("recent.txt").splitWhitespace:
    try: result.add parseHexInt(x)
    except ValueError: discard

proc used(cp: int) =
  ## the character goes to the top of the ones used last
  let keep = setting("recent", 8)
  if keep <= 0: return
  var r = @[cp]
  for x in recents():
    if x != cp and r.len < keep: r.add x
  var s: seq[string]
  for x in r: s.add toHex(x, 4)
  writeData("recent.txt", s.join(" ") & "\n")

proc put(b: Buf, cp: int) =
  ## the character at the cursor (over the selection), the cursor after it
  let s = utf8Of(cp)
  let r = b.selection
  let at = if r.isEmpty: b.cursor else: r.start
  b.replace(if r.isEmpty: rng(at, at) else: r, s)
  b.setCursor(pos(at.line, at.col + s.len))
  used(cp)

proc insertChar() =
  let b = current()
  if not b.valid:
    message("Open a file first")
    return
  load()
  var order: seq[int]                   # (indexes into chars: the recent ones first, then the table's order)
  var items, details: seq[string]
  let keep = setting("recent", 8)
  if keep > 0:
    for cp in recents():
      for i, c in chars:
        if c.cp == cp and c.group != "-":
          order.add i
          items.add label(c)
          details.add uplus(c.cp) & " · used lately"
          break
  for i, c in chars:
    if c.group == "-": continue
    order.add i
    items.add label(c)
    details.add uplus(c.cp) & " · " & c.group
  let k = pick("Insert a character — type part of its name", items, details)
  if k >= 0: put(b, chars[order[k]].cp)

func parseCodePoint(s: string): int =
  ## U+2192, u2192, 0x2192, 2192, &#8594;, &#x2192; → the code point (-1: not one)
  var t = s.strip
  var hex = true
  if t.startsWith("&#") and t.endsWith(";"):
    t = t[2 ..< t.high]
    if t.len > 0 and t[0] in {'x', 'X'}: t = t[1 .. ^1]
    else: hex = false
  elif t.len > 2 and t[0] in {'U', 'u'} and t[1] == '+': t = t[2 .. ^1]
  elif t.len > 1 and t[0] in {'U', 'u'}: t = t[1 .. ^1]
  elif t.len > 2 and t[0] == '0' and t[1] in {'x', 'X'}: t = t[2 .. ^1]
  if t.len == 0 or t.len > 8: return -1
  for c in t:
    if c notin (if hex: HexDigits else: Digits): return -1
  result = if hex: parseHexInt(t) else: parseInt(t)
  if result > 0x10FFFF or result in 0xD800 .. 0xDFFF: result = -1

proc insertByCode() =
  let b = current()
  if not b.valid:
    message("Open a file first")
    return
  let s = ask("Code point (U+2192, 2192, &#8594;)")
  if s.len == 0: return
  let cp = parseCodePoint(s)
  if cp < 0:
    warn("Not a code point: " & s & " — write it as U+2192, 2192 or &#8594;")
    return
  put(b, cp)
  message(uplus(cp) & "  " & nameOf(cp))

proc underCursor() =
  let b = current()
  if not b.valid:
    message("Open a file first")
    return
  let p = b.cursor
  message(describe(b.line(p.line), p.col))

command "Insert a character…", "ctrl+alt+u": insertChar()
command "Insert a character by its code point…": insertByCode()
command "Character under the cursor: name and code point": underCursor()

nmap("g8", "the character under the cursor: its code point, name and UTF-8 bytes") do (count: int): underCursor()
