#include <algorithm>
#include <array>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <unordered_set>
#include <vector>

namespace {

constexpr int TAB_STOP = 4;
constexpr int KEY_NULL = -1;

int ctrlKey(char c) {
    return c & 0x1f;
}

enum Key {
    ARROW_LEFT = 1000,
    ARROW_RIGHT,
    ARROW_UP,
    ARROW_DOWN,
    DEL_KEY,
    HOME_KEY,
    END_KEY,
    PAGE_UP,
    PAGE_DOWN,
    BACKTAB
};

enum class Language {
    SuperCollider,
    ChucK,
    Cpp,
    Plain
};

enum class Kind {
    Normal,
    Comment,
    Keyword,
    Type,
    Builtin,
    Number,
    String,
    Symbol,
    Operator,
    Preprocessor,
    Search,
    Match,
    Paren0,
    Paren1,
    Paren2,
    Paren3,
    Paren4,
    Paren5
};

struct Rgb {
    int r = 255;
    int g = 255;
    int b = 255;
};

struct Style {
    Rgb fg;
    Rgb bg;
    bool bold = false;
    bool italic = false;
};

bool operator==(const Rgb& a, const Rgb& b) {
    return a.r == b.r && a.g == b.g && a.b == b.b;
}

bool operator==(const Style& a, const Style& b) {
    return a.fg == b.fg && a.bg == b.bg && a.bold == b.bold && a.italic == b.italic;
}

struct Position {
    int row = 0;
    int col = 0;
};

struct Theme {
    Rgb bg{12, 13, 24};
    Rgb activeBg{27, 25, 48};
    Rgb statusBg{244, 79, 255};
    Rgb statusFg{18, 13, 28};
    Rgb promptBg{18, 22, 38};
    Rgb promptFg{244, 248, 255};
    Rgb gutterFg{122, 130, 180};
    Rgb gutterActiveFg{255, 231, 105};
    Rgb normal{242, 242, 250};
    Rgb dim{112, 119, 164};
    Rgb comment{95, 238, 171};
    Rgb keyword{255, 69, 226};
    Rgb type{80, 218, 255};
    Rgb builtin{255, 223, 84};
    Rgb number{255, 145, 82};
    Rgb string{107, 255, 145};
    Rgb symbol{255, 188, 71};
    Rgb op{248, 248, 255};
    Rgb preprocessor{184, 151, 255};
    Rgb searchBg{255, 240, 76};
    Rgb searchFg{31, 24, 39};
    Rgb matchBg{255, 77, 121};
    Rgb matchFg{255, 255, 255};
    std::array<Rgb, 6> parens{{
        {255, 92, 210},
        {70, 225, 255},
        {255, 220, 80},
        {119, 255, 138},
        {255, 141, 82},
        {183, 126, 255}
    }};
};

const Theme& theme() {
    static Theme t;
    return t;
}

std::string rgbFg(Rgb c) {
    return "\x1b[38;2;" + std::to_string(c.r) + ";" + std::to_string(c.g) + ";" + std::to_string(c.b) + "m";
}

std::string rgbBg(Rgb c) {
    return "\x1b[48;2;" + std::to_string(c.r) + ";" + std::to_string(c.g) + ";" + std::to_string(c.b) + "m";
}

std::string styleAnsi(const Style& s) {
    std::string out = "\x1b[0m";
    if (s.bold) out += "\x1b[1m";
    if (s.italic) out += "\x1b[3m";
    out += rgbFg(s.fg);
    out += rgbBg(s.bg);
    return out;
}

Style styleFor(Kind kind, bool activeLine = false) {
    const Theme& t = theme();
    Rgb bg = activeLine ? t.activeBg : t.bg;
    switch (kind) {
        case Kind::Comment: return {t.comment, bg, false, true};
        case Kind::Keyword: return {t.keyword, bg, true, false};
        case Kind::Type: return {t.type, bg, true, false};
        case Kind::Builtin: return {t.builtin, bg, true, false};
        case Kind::Number: return {t.number, bg, true, false};
        case Kind::String: return {t.string, bg, false, false};
        case Kind::Symbol: return {t.symbol, bg, true, false};
        case Kind::Operator: return {t.op, bg, true, false};
        case Kind::Preprocessor: return {t.preprocessor, bg, true, false};
        case Kind::Search: return {t.searchFg, t.searchBg, true, false};
        case Kind::Match: return {t.matchFg, t.matchBg, true, false};
        case Kind::Paren0: return {t.parens[0], bg, true, false};
        case Kind::Paren1: return {t.parens[1], bg, true, false};
        case Kind::Paren2: return {t.parens[2], bg, true, false};
        case Kind::Paren3: return {t.parens[3], bg, true, false};
        case Kind::Paren4: return {t.parens[4], bg, true, false};
        case Kind::Paren5: return {t.parens[5], bg, true, false};
        case Kind::Normal:
        default: return {t.normal, bg, false, false};
    }
}

std::string languageName(Language lang) {
    switch (lang) {
        case Language::SuperCollider: return "SuperCollider";
        case Language::ChucK: return "ChucK";
        case Language::Cpp: return "C++";
        case Language::Plain: return "Plain";
    }
    return "Plain";
}

std::string toLower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

std::string trim(std::string value) {
    auto notSpace = [](unsigned char c) { return !std::isspace(c); };
    value.erase(value.begin(), std::find_if(value.begin(), value.end(), notSpace));
    value.erase(std::find_if(value.rbegin(), value.rend(), notSpace).base(), value.end());
    return value;
}

bool endsWith(const std::string& s, const std::string& suffix) {
    return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

Language detectLanguage(const std::string& filename, const std::vector<std::string>& rows) {
    std::string lower = toLower(filename);
    if (endsWith(lower, ".scd") || endsWith(lower, ".sc")) return Language::SuperCollider;
    if (endsWith(lower, ".ck")) return Language::ChucK;
    if (endsWith(lower, ".cpp") || endsWith(lower, ".cc") || endsWith(lower, ".cxx") ||
        endsWith(lower, ".hpp") || endsWith(lower, ".hh") || endsWith(lower, ".h")) {
        return Language::Cpp;
    }

    for (const std::string& row : rows) {
        if (row.find("SynthDef") != std::string::npos || row.find("SinOsc.ar") != std::string::npos) {
            return Language::SuperCollider;
        }
        if (row.find("=>") != std::string::npos || row.find("::ms") != std::string::npos ||
            row.find("now") != std::string::npos) {
            return Language::ChucK;
        }
    }
    return Language::Plain;
}

std::string expandPath(std::string path) {
    if (path == "~" || path.rfind("~/", 0) == 0) {
        if (const char* home = std::getenv("HOME")) {
            return std::string(home) + path.substr(1);
        }
    }
    return path;
}

std::string baseName(const std::string& path) {
    if (path.empty()) return "[untitled]";
    std::size_t slash = path.find_last_of('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

std::string shellQuote(const std::string& value) {
    std::string out = "'";
    for (char c : value) {
        if (c == '\'') out += "'\\''";
        else out += c;
    }
    out += "'";
    return out;
}

bool commandExists(const std::string& command) {
    std::string probe = "command -v " + shellQuote(command) + " >/dev/null 2>&1";
    return std::system(probe.c_str()) == 0;
}

bool isIdentStart(char c) {
    unsigned char uc = static_cast<unsigned char>(c);
    return std::isalpha(uc) || c == '_';
}

bool isIdent(char c) {
    unsigned char uc = static_cast<unsigned char>(c);
    return std::isalnum(uc) || c == '_';
}

bool isOpenBracket(char c) {
    return c == '(' || c == '[' || c == '{';
}

bool isCloseBracket(char c) {
    return c == ')' || c == ']' || c == '}';
}

char matchingBracket(char c) {
    switch (c) {
        case '(': return ')';
        case '[': return ']';
        case '{': return '}';
        case ')': return '(';
        case ']': return '[';
        case '}': return '{';
        default: return '\0';
    }
}

const std::unordered_set<std::string>& superColliderKeywords() {
    static const std::unordered_set<std::string> words = {
        "arg", "var", "class", "this", "super", "nil", "true", "false", "inf",
        "if", "while", "for", "do", "case", "switch", "return", "break",
        "continue", "try", "catch", "protect", "new", "value", "play", "add",
        "kr", "ar", "ir"
    };
    return words;
}

const std::unordered_set<std::string>& superColliderBuiltins() {
    static const std::unordered_set<std::string> words = {
        "SynthDef", "Synth", "Server", "Routine", "Task", "Pattern", "Pbind",
        "Pseq", "Prand", "Pwhite", "Pfunc", "Dseq", "Demand", "Env", "EnvGen",
        "SinOsc", "Pulse", "Saw", "LFSaw", "VarSaw", "Blip", "WhiteNoise",
        "PinkNoise", "BrownNoise", "Impulse", "Dust", "LFNoise0", "LFNoise1",
        "LFNoise2", "LFTri", "LFPulse", "BPF", "RLPF", "LPF", "HPF", "BRF",
        "MoogFF", "CombN", "CombL", "AllpassN", "FreeVerb", "DelayN", "Pan2",
        "Splay", "Out", "In", "BufRd", "BufWr", "PlayBuf", "RecordBuf",
        "MouseX", "MouseY", "Line", "XLine", "Decay", "Decay2", "Lag", "Mix",
        "Select", "TChoose", "TRand"
    };
    return words;
}

const std::unordered_set<std::string>& chuckKeywords() {
    static const std::unordered_set<std::string> words = {
        "class", "extends", "public", "static", "pure", "this", "super", "new",
        "function", "fun", "if", "else", "while", "until", "for", "repeat",
        "break", "continue", "return", "spork", "me", "now", "true", "false",
        "null", "maybe"
    };
    return words;
}

const std::unordered_set<std::string>& chuckTypes() {
    static const std::unordered_set<std::string> words = {
        "int", "float", "dur", "time", "string", "void", "same", "Event",
        "Object", "UGen", "UAna", "Shred"
    };
    return words;
}

const std::unordered_set<std::string>& chuckBuiltins() {
    static const std::unordered_set<std::string> words = {
        "SinOsc", "TriOsc", "SawOsc", "SqrOsc", "PulseOsc", "Noise", "Blit",
        "ADSR", "Envelope", "Delay", "DelayA", "DelayL", "JCRev", "NRev",
        "LPF", "HPF", "BPF", "BRF", "Pan2", "Gain", "dac", "adc", "blackhole",
        "Std", "Math", "Machine", "second", "ms", "samp", "minute", "hour",
        "day", "week"
    };
    return words;
}

const std::unordered_set<std::string>& cppKeywords() {
    static const std::unordered_set<std::string> words = {
        "alignas", "alignof", "and", "asm", "auto", "bitand", "bitor", "bool",
        "break", "case", "catch", "char", "char16_t", "char32_t", "class",
        "compl", "concept", "const", "constexpr", "const_cast", "continue",
        "decltype", "default", "delete", "do", "double", "dynamic_cast", "else",
        "enum", "explicit", "export", "extern", "false", "float", "for",
        "friend", "goto", "if", "inline", "int", "long", "mutable", "namespace",
        "new", "noexcept", "not", "nullptr", "operator", "or", "private",
        "protected", "public", "register", "reinterpret_cast", "requires",
        "return", "short", "signed", "sizeof", "static", "static_assert",
        "static_cast", "struct", "switch", "template", "this", "thread_local",
        "throw", "true", "try", "typedef", "typeid", "typename", "union",
        "unsigned", "using", "virtual", "void", "volatile", "wchar_t", "while",
        "xor"
    };
    return words;
}

const std::unordered_set<std::string>& cppTypes() {
    static const std::unordered_set<std::string> words = {
        "std", "string", "vector", "array", "optional", "unordered_set",
        "size_t", "int64_t", "uint64_t", "pid_t", "FILE", "termios", "ifstream",
        "ofstream", "stringstream", "ostringstream"
    };
    return words;
}

const std::unordered_set<std::string>& cppBuiltins() {
    static const std::unordered_set<std::string> words = {
        "read", "write", "open", "close", "fork", "pipe", "dup2", "execl",
        "waitpid", "kill", "tcgetattr", "tcsetattr", "ioctl", "std"
    };
    return words;
}

Kind classifyIdentifier(const std::string& word, Language lang) {
    if (lang == Language::SuperCollider) {
        if (superColliderKeywords().count(word)) return Kind::Keyword;
        if (superColliderBuiltins().count(word)) return Kind::Builtin;
        if (!word.empty() && std::isupper(static_cast<unsigned char>(word.front()))) return Kind::Type;
    } else if (lang == Language::ChucK) {
        if (chuckKeywords().count(word)) return Kind::Keyword;
        if (chuckTypes().count(word)) return Kind::Type;
        if (chuckBuiltins().count(word)) return Kind::Builtin;
        if (!word.empty() && std::isupper(static_cast<unsigned char>(word.front()))) return Kind::Type;
    } else if (lang == Language::Cpp) {
        if (cppKeywords().count(word)) return Kind::Keyword;
        if (cppTypes().count(word)) return Kind::Type;
        if (cppBuiltins().count(word)) return Kind::Builtin;
        if (!word.empty() && std::isupper(static_cast<unsigned char>(word.front()))) return Kind::Type;
    }
    return Kind::Normal;
}

void markRange(std::vector<Kind>& kinds, std::size_t start, std::size_t end, Kind kind) {
    end = std::min(end, kinds.size());
    for (std::size_t i = start; i < end; ++i) kinds[i] = kind;
}

std::vector<Kind> highlightLine(const std::string& line, Language lang, bool& inBlockComment, int& parenDepth) {
    std::vector<Kind> kinds(line.size(), Kind::Normal);
    std::size_t i = 0;
    const std::size_t n = line.size();

    while (i < n) {
        if (inBlockComment) {
            std::size_t end = line.find("*/", i);
            if (end == std::string::npos) {
                markRange(kinds, i, n, Kind::Comment);
                return kinds;
            }
            markRange(kinds, i, end + 2, Kind::Comment);
            i = end + 2;
            inBlockComment = false;
            continue;
        }

        char c = line[i];
        char next = (i + 1 < n) ? line[i + 1] : '\0';

        if (lang == Language::Cpp && c == '#') {
            bool onlySpaceBefore = true;
            for (std::size_t j = 0; j < i; ++j) {
                if (!std::isspace(static_cast<unsigned char>(line[j]))) {
                    onlySpaceBefore = false;
                    break;
                }
            }
            if (onlySpaceBefore) {
                markRange(kinds, i, n, Kind::Preprocessor);
                return kinds;
            }
        }

        if (c == '/' && next == '/') {
            markRange(kinds, i, n, Kind::Comment);
            return kinds;
        }

        if (c == '/' && next == '*') {
            std::size_t end = line.find("*/", i + 2);
            if (end == std::string::npos) {
                markRange(kinds, i, n, Kind::Comment);
                inBlockComment = true;
                return kinds;
            }
            markRange(kinds, i, end + 2, Kind::Comment);
            i = end + 2;
            continue;
        }

        if (c == '"' || c == '\'') {
            char quote = c;
            std::size_t start = i++;
            bool escaped = false;
            while (i < n) {
                char sc = line[i++];
                if (escaped) {
                    escaped = false;
                } else if (sc == '\\') {
                    escaped = true;
                } else if (sc == quote) {
                    break;
                }
            }
            markRange(kinds, start, i, Kind::String);
            continue;
        }

        if (lang == Language::SuperCollider && c == '\\' && (i + 1 < n) &&
            (isIdentStart(line[i + 1]) || std::isdigit(static_cast<unsigned char>(line[i + 1])))) {
            std::size_t start = i++;
            while (i < n && (isIdent(line[i]) || line[i] == '-' || line[i] == '_')) ++i;
            markRange(kinds, start, i, Kind::Symbol);
            continue;
        }

        if (std::isdigit(static_cast<unsigned char>(c)) ||
            (c == '.' && std::isdigit(static_cast<unsigned char>(next)))) {
            std::size_t start = i;
            if (c == '0' && (next == 'x' || next == 'X')) {
                i += 2;
                while (i < n && std::isxdigit(static_cast<unsigned char>(line[i]))) ++i;
            } else {
                while (i < n && std::isdigit(static_cast<unsigned char>(line[i]))) ++i;
                if (i < n && line[i] == '.') {
                    ++i;
                    while (i < n && std::isdigit(static_cast<unsigned char>(line[i]))) ++i;
                }
                if (i < n && (line[i] == 'e' || line[i] == 'E')) {
                    ++i;
                    if (i < n && (line[i] == '+' || line[i] == '-')) ++i;
                    while (i < n && std::isdigit(static_cast<unsigned char>(line[i]))) ++i;
                }
            }
            while (i < n && (line[i] == '_' || std::isalpha(static_cast<unsigned char>(line[i])))) ++i;
            markRange(kinds, start, i, Kind::Number);
            continue;
        }

        if (isIdentStart(c)) {
            std::size_t start = i++;
            while (i < n && isIdent(line[i])) ++i;
            std::string word = line.substr(start, i - start);
            markRange(kinds, start, i, classifyIdentifier(word, lang));
            continue;
        }

        if (isOpenBracket(c)) {
            Kind paren = static_cast<Kind>(static_cast<int>(Kind::Paren0) + (parenDepth % 6));
            kinds[i++] = paren;
            ++parenDepth;
            continue;
        }

        if (isCloseBracket(c)) {
            parenDepth = std::max(0, parenDepth - 1);
            Kind paren = static_cast<Kind>(static_cast<int>(Kind::Paren0) + (parenDepth % 6));
            kinds[i++] = paren;
            continue;
        }

        if (std::strchr("+-*%=!<>|&^~?:;,.@$/", c) != nullptr) {
            kinds[i++] = Kind::Operator;
            continue;
        }

        ++i;
    }

    return kinds;
}

class Terminal {
public:
    void enable() {
        if (!isatty(STDIN_FILENO)) {
            throw std::runtime_error("SourCe needs an interactive terminal.");
        }
        if (tcgetattr(STDIN_FILENO, &original_) == -1) {
            throw std::runtime_error("Could not read terminal settings.");
        }
        termios raw = original_;
        raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
        raw.c_oflag &= ~(OPOST);
        raw.c_cflag |= (CS8);
        raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
        raw.c_cc[VMIN] = 0;
        raw.c_cc[VTIME] = 1;
        if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == -1) {
            throw std::runtime_error("Could not enter raw terminal mode.");
        }
        rawEnabled_ = true;
        writeOut("\x1b[?1049h\x1b[?25l");
    }

    ~Terminal() {
        disable();
    }

    void disable() {
        if (rawEnabled_) {
            writeOut("\x1b[0m\x1b[?25h\x1b[?1049l");
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original_);
            rawEnabled_ = false;
        }
    }

    static void writeOut(const std::string& s) {
        ssize_t ignored = ::write(STDOUT_FILENO, s.data(), s.size());
        (void)ignored;
    }

private:
    termios original_{};
    bool rawEnabled_ = false;
};

int readByte() {
    char c = '\0';
    ssize_t n = ::read(STDIN_FILENO, &c, 1);
    if (n == 1) return static_cast<unsigned char>(c);
    if (n == -1 && errno != EAGAIN) return KEY_NULL;
    return KEY_NULL;
}

int readKey() {
    int c = readByte();
    if (c == KEY_NULL) return KEY_NULL;

    if (c == '\x1b') {
        int a = readByte();
        if (a == KEY_NULL) return '\x1b';
        int b = readByte();
        if (b == KEY_NULL) return '\x1b';

        if (a == '[') {
            if (b >= '0' && b <= '9') {
                int c3 = readByte();
                if (c3 == '~') {
                    switch (b) {
                        case '1': return HOME_KEY;
                        case '3': return DEL_KEY;
                        case '4': return END_KEY;
                        case '5': return PAGE_UP;
                        case '6': return PAGE_DOWN;
                        case '7': return HOME_KEY;
                        case '8': return END_KEY;
                    }
                } else if (b == '1' && c3 == ';') {
                    int c4 = readByte();
                    int c5 = readByte();
                    (void)c4;
                    if (c5 == 'Z') return BACKTAB;
                }
            } else {
                switch (b) {
                    case 'A': return ARROW_UP;
                    case 'B': return ARROW_DOWN;
                    case 'C': return ARROW_RIGHT;
                    case 'D': return ARROW_LEFT;
                    case 'H': return HOME_KEY;
                    case 'F': return END_KEY;
                    case 'Z': return BACKTAB;
                }
            }
        } else if (a == 'O') {
            switch (b) {
                case 'H': return HOME_KEY;
                case 'F': return END_KEY;
            }
        }
        return '\x1b';
    }

    return c;
}

class Editor {
public:
    Editor() {
        rows_.push_back("");
        setStatus("Ctrl-G help  Ctrl-P command palette  Ctrl-Y self-source");
    }

    void loadWelcomeBuffer() {
        filename_.clear();
        language_ = Language::SuperCollider;
        rows_ = {
            "// SourCe: a juicy SuperCollider and ChucK editor",
            "// Ctrl-Y opens the C++ source and highlights the highlighter itself.",
            "",
            "(",
            "SynthDef(\\sourceTextGlow, { |freq = 220, amp = 0.18|",
            "    var pulse = Impulse.kr(8);",
            "    var env = Decay2.kr(pulse, 0.01, 0.32);",
            "    var tone = SinOsc.ar(freq * [1, 1.005, 2.01]).sum * env;",
            "    var color = BPF.ar(WhiteNoise.ar(0.06), freq * 6, 0.12);",
            "    Out.ar(0, Pan2.ar((tone + color) * amp, LFNoise1.kr(0.4)));",
            "}).add;",
            ")"
        };
        dirty_ = false;
        cx_ = cy_ = rowoff_ = coloff_ = 0;
        markHighlightDirty();
    }

    bool openFile(const std::string& path) {
        std::string expanded = expandPath(path);
        std::ifstream in(expanded);
        if (!in) {
            setStatus("Could not open: " + expanded);
            return false;
        }

        std::vector<std::string> loaded;
        std::string line;
        while (std::getline(in, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            loaded.push_back(line);
        }
        if (loaded.empty()) loaded.push_back("");

        rows_ = std::move(loaded);
        filename_ = expanded;
        language_ = detectLanguage(filename_, rows_);
        dirty_ = false;
        cx_ = cy_ = rowoff_ = coloff_ = 0;
        searchTerm_.clear();
        markHighlightDirty();
        setStatus("Opened " + baseName(filename_) + " as " + languageName(language_));
        return true;
    }

    void openSelfSource() {
        if (!maybeDiscardDirty()) return;
        if (!openFile(JUICY_SOURCE_PATH)) {
            setStatus("Could not open self source path compiled into the binary.");
        } else {
            language_ = Language::Cpp;
            setStatus("Self-highlight mode: this editor is now coloring its own C++ source.");
            markHighlightDirty();
        }
    }

    void loop() {
        while (running_) {
            pollRunner();
            refreshScreen();
            int key = readKey();
            if (key != KEY_NULL) processKey(key);
        }
    }

private:
    std::vector<std::string> rows_;
    std::vector<std::vector<Kind>> highlights_;
    std::string filename_;
    Language language_ = Language::SuperCollider;
    bool dirty_ = false;
    bool highlightDirty_ = true;
    bool running_ = true;
    bool showHelp_ = false;

    int cx_ = 0;
    int cy_ = 0;
    int rowoff_ = 0;
    int coloff_ = 0;
    int screenRows_ = 24;
    int screenCols_ = 80;
    int contentRows_ = 20;
    int consoleRows_ = 0;
    int quitConfirm_ = 0;

    std::string status_;
    std::time_t statusTime_ = 0;
    bool promptActive_ = false;
    std::string promptLabel_;
    std::string promptBuffer_;

    std::string searchTerm_;
    std::optional<Position> matchA_;
    std::optional<Position> matchB_;

    pid_t runnerPid_ = -1;
    int runnerFd_ = -1;
    std::string runnerPartial_;
    std::vector<std::string> console_;

    void markHighlightDirty() {
        highlightDirty_ = true;
    }

    int gutterWidth() const {
        int digits = static_cast<int>(std::to_string(std::max<std::size_t>(1, rows_.size())).size());
        return digits + 2;
    }

    int codeWidth() const {
        return std::max(1, screenCols_ - gutterWidth());
    }

    void updateWindowSize() {
        winsize ws{};
        if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == -1 || ws.ws_col == 0) {
            screenRows_ = 24;
            screenCols_ = 80;
        } else {
            screenRows_ = ws.ws_row;
            screenCols_ = ws.ws_col;
        }

        bool wantsConsole = runnerPid_ > 0 || !console_.empty();
        consoleRows_ = wantsConsole ? std::min(5, std::max(0, screenRows_ - 7)) : 0;
        contentRows_ = std::max(1, screenRows_ - 2 - consoleRows_);
    }

    void ensureHighlights() {
        if (!highlightDirty_) return;
        highlights_.clear();
        highlights_.reserve(rows_.size());
        bool inBlock = false;
        int parenDepth = 0;
        for (const std::string& row : rows_) {
            highlights_.push_back(highlightLine(row, language_, inBlock, parenDepth));
        }
        highlightDirty_ = false;
    }

    void setStatus(std::string message) {
        status_ = std::move(message);
        statusTime_ = std::time(nullptr);
    }

    int rowCxToRx(int row, int cx) const {
        if (row < 0 || row >= static_cast<int>(rows_.size())) return 0;
        const std::string& line = rows_[row];
        int rx = 0;
        int limit = std::min<int>(cx, line.size());
        for (int i = 0; i < limit; ++i) {
            if (line[i] == '\t') rx += TAB_STOP - (rx % TAB_STOP);
            else ++rx;
        }
        return rx;
    }

    void scroll() {
        if (cy_ < rowoff_) rowoff_ = cy_;
        if (cy_ >= rowoff_ + contentRows_) rowoff_ = cy_ - contentRows_ + 1;

        int rx = rowCxToRx(cy_, cx_);
        if (rx < coloff_) coloff_ = rx;
        if (rx >= coloff_ + codeWidth()) coloff_ = rx - codeWidth() + 1;
    }

    void refreshScreen() {
        updateWindowSize();
        ensureHighlights();
        updateBracketMatch();
        scroll();

        std::string out;
        out.reserve(static_cast<std::size_t>(screenRows_ * screenCols_ * 4));
        out += "\x1b[?25l";
        out += "\x1b[H";

        for (int y = 0; y < contentRows_; ++y) {
            drawEditorRow(out, y);
        }
        drawConsole(out);
        drawStatusBar(out);
        drawMessageBar(out);
        if (showHelp_) drawHelp(out);

        int cursorY = (cy_ - rowoff_) + 1;
        int cursorX = gutterWidth() + (rowCxToRx(cy_, cx_) - coloff_) + 1;
        cursorY = std::clamp(cursorY, 1, std::max(1, contentRows_));
        cursorX = std::clamp(cursorX, 1, std::max(1, screenCols_));
        out += "\x1b[" + std::to_string(cursorY) + ";" + std::to_string(cursorX) + "H";
        out += "\x1b[?25h";
        Terminal::writeOut(out);
    }

    void emitStyle(std::string& out, const Style& style, std::optional<Style>& current) {
        if (!current || !(style == *current)) {
            out += styleAnsi(style);
            current = style;
        }
    }

    void drawEditorRow(std::string& out, int screenY) {
        int fileRow = rowoff_ + screenY;
        const Theme& t = theme();
        bool active = fileRow == cy_;
        Style base{t.normal, active ? t.activeBg : t.bg, false, false};
        out += styleAnsi(base);

        if (fileRow >= static_cast<int>(rows_.size())) {
            Style gutter{t.dim, t.bg, true, false};
            out += styleAnsi(gutter);
            out += " ~";
            out += "\x1b[0m\x1b[K\r\n";
            return;
        }

        drawLineNumber(out, fileRow, active);
        drawCode(out, fileRow, active);
        out += "\x1b[0m\x1b[K";
        if (screenY < contentRows_ - 1 || consoleRows_ > 0 || true) out += "\r\n";
    }

    void drawLineNumber(std::string& out, int fileRow, bool active) {
        const Theme& t = theme();
        int width = gutterWidth();
        std::ostringstream number;
        number << std::setw(width - 1) << (fileRow + 1) << " ";
        Style style{active ? t.gutterActiveFg : t.gutterFg, active ? t.activeBg : t.bg, true, false};
        out += styleAnsi(style);
        out += number.str();
    }

    void overlaySearch(std::vector<Kind>& kinds, const std::string& line) {
        if (searchTerm_.empty()) return;
        std::size_t pos = line.find(searchTerm_);
        while (pos != std::string::npos) {
            markRange(kinds, pos, pos + searchTerm_.size(), Kind::Search);
            pos = line.find(searchTerm_, pos + std::max<std::size_t>(1, searchTerm_.size()));
        }
    }

    void overlayBracketMatches(std::vector<Kind>& kinds, int fileRow) {
        if (matchA_ && matchA_->row == fileRow && matchA_->col >= 0 && matchA_->col < static_cast<int>(kinds.size())) {
            kinds[matchA_->col] = Kind::Match;
        }
        if (matchB_ && matchB_->row == fileRow && matchB_->col >= 0 && matchB_->col < static_cast<int>(kinds.size())) {
            kinds[matchB_->col] = Kind::Match;
        }
    }

    void drawCode(std::string& out, int fileRow, bool active) {
        const std::string& line = rows_[fileRow];
        std::vector<Kind> kinds = fileRow < static_cast<int>(highlights_.size())
            ? highlights_[fileRow]
            : std::vector<Kind>(line.size(), Kind::Normal);
        overlaySearch(kinds, line);
        overlayBracketMatches(kinds, fileRow);

        int visible = 0;
        int visualCol = 0;
        std::optional<Style> current;
        for (std::size_t i = 0; i < line.size(); ++i) {
            char c = line[i];
            int width = (c == '\t') ? (TAB_STOP - (visualCol % TAB_STOP)) : 1;
            Kind kind = i < kinds.size() ? kinds[i] : Kind::Normal;
            Style style = styleFor(kind, active);

            for (int w = 0; w < width; ++w) {
                if (visualCol >= coloff_ && visible < codeWidth()) {
                    emitStyle(out, style, current);
                    if (c == '\t') {
                        out += ' ';
                    } else if (std::iscntrl(static_cast<unsigned char>(c))) {
                        out += '?';
                    } else {
                        out += c;
                    }
                    ++visible;
                }
                ++visualCol;
            }
        }

        Style fill{theme().normal, active ? theme().activeBg : theme().bg, false, false};
        emitStyle(out, fill, current);
        while (visible < codeWidth()) {
            out += ' ';
            ++visible;
        }
    }

    void drawConsole(std::string& out) {
        if (consoleRows_ <= 0) return;
        const Theme& t = theme();
        Style header{t.builtin, {15, 20, 34}, true, false};
        Style lineStyle{t.normal, {15, 20, 34}, false, false};
        std::string title = runnerPid_ > 0 ? " runner active: Ctrl-T stops " : " runner output ";

        out += styleAnsi(header);
        out += title;
        if (static_cast<int>(title.size()) < screenCols_) {
            out += std::string(screenCols_ - title.size(), '-');
        }
        out += "\x1b[0m\r\n";

        int linesAvailable = std::max(0, consoleRows_ - 1);
        int start = std::max(0, static_cast<int>(console_.size()) - linesAvailable);
        for (int i = 0; i < linesAvailable; ++i) {
            out += styleAnsi(lineStyle);
            std::string line;
            if (start + i < static_cast<int>(console_.size())) line = console_[start + i];
            if (static_cast<int>(line.size()) > screenCols_) line = line.substr(0, screenCols_);
            out += line;
            if (static_cast<int>(line.size()) < screenCols_) out += std::string(screenCols_ - line.size(), ' ');
            out += "\x1b[0m";
            if (i != linesAvailable - 1) out += "\r\n";
        }
        if (linesAvailable > 0) out += "\r\n";
    }

    void drawStatusBar(std::string& out) {
        const Theme& t = theme();
        Style style{t.statusFg, t.statusBg, true, false};
        out += styleAnsi(style);

        std::string left = " " + baseName(filename_) + (dirty_ ? " *" : "  ");
        left += " | " + languageName(language_);
        if (runnerPid_ > 0) left += " | running";

        std::ostringstream right;
        right << "Ln " << (cy_ + 1) << ", Col " << (cx_ + 1) << " ";

        int space = screenCols_ - static_cast<int>(left.size()) - static_cast<int>(right.str().size());
        if (space < 1) {
            std::string clipped = left.substr(0, std::max(0, screenCols_ - static_cast<int>(right.str().size()) - 1));
            out += clipped;
            space = screenCols_ - static_cast<int>(clipped.size()) - static_cast<int>(right.str().size());
        } else {
            out += left;
        }
        if (space > 0) out += std::string(space, ' ');
        out += right.str();
        out += "\x1b[0m\r\n";
    }

    void drawMessageBar(std::string& out) {
        const Theme& t = theme();
        Style style{t.promptFg, t.promptBg, false, false};
        out += styleAnsi(style);

        std::string message;
        if (promptActive_) {
            message = promptLabel_ + promptBuffer_;
        } else if (!status_.empty() && std::difftime(std::time(nullptr), statusTime_) < 7.0) {
            message = status_;
        } else {
            message = "Ctrl-S save  Ctrl-R run  Ctrl-F search  Ctrl-L language  Ctrl-Y self";
        }

        if (static_cast<int>(message.size()) > screenCols_) message = message.substr(0, screenCols_);
        out += message;
        if (static_cast<int>(message.size()) < screenCols_) out += std::string(screenCols_ - message.size(), ' ');
        out += "\x1b[0m";
    }

    void drawHelp(std::string& out) {
        std::vector<std::string> lines = {
            " SourCe ",
            " Ctrl-S save        Ctrl-O open        Ctrl-Q quit ",
            " Ctrl-F search      Ctrl-N next        Ctrl-J goto line ",
            " Ctrl-R run         Ctrl-T stop        Ctrl-L cycle language ",
            " Ctrl-Y self-source Ctrl-D duplicate   Ctrl-/ comment ",
            " Ctrl-P commands    Tab indent         Enter auto-indent ",
            " ",
            " SuperCollider and ChucK get neon token colors, rainbow brackets,",
            " search glow, bracket matching, auto-pairs, and a runner panel.",
            " Press any key to return. "
        };

        int width = 0;
        for (const auto& line : lines) width = std::max(width, static_cast<int>(line.size()));
        width = std::min(width + 2, std::max(10, screenCols_ - 4));
        int height = static_cast<int>(lines.size()) + 2;
        int top = std::max(1, (screenRows_ - height) / 2 + 1);
        int left = std::max(1, (screenCols_ - width) / 2 + 1);
        Style box{{245, 248, 255}, {35, 28, 58}, false, false};
        Style title{{255, 230, 83}, {35, 28, 58}, true, false};

        for (int y = 0; y < height; ++y) {
            out += "\x1b[" + std::to_string(top + y) + ";" + std::to_string(left) + "H";
            out += styleAnsi(y == 1 ? title : box);
            std::string text;
            if (y == 0 || y == height - 1) {
                text = std::string(width, ' ');
            } else {
                text = " " + lines[y - 1];
                if (static_cast<int>(text.size()) < width) text += std::string(width - text.size(), ' ');
                if (static_cast<int>(text.size()) > width) text = text.substr(0, width);
            }
            out += text;
            out += "\x1b[0m";
        }
    }

    void processKey(int key) {
        if (showHelp_) {
            showHelp_ = false;
            return;
        }

        if (key != ctrlKey('q')) quitConfirm_ = 2;

        switch (key) {
            case ctrlKey('q'):
                quit();
                break;
            case ctrlKey('s'):
                saveFile();
                break;
            case ctrlKey('o'):
                openPrompt();
                break;
            case ctrlKey('f'):
                searchPrompt();
                break;
            case ctrlKey('n'):
                findNext(true);
                break;
            case ctrlKey('j'):
                gotoLinePrompt();
                break;
            case ctrlKey('r'):
                runBuffer();
                break;
            case ctrlKey('t'):
                stopRunner();
                break;
            case ctrlKey('l'):
                cycleLanguage();
                break;
            case ctrlKey('y'):
                openSelfSource();
                break;
            case ctrlKey('d'):
                duplicateLine();
                break;
            case ctrlKey('g'):
                showHelp_ = true;
                break;
            case ctrlKey('p'):
                commandPalette();
                break;
            case 31:
                toggleComment();
                break;
            case '\r':
                insertNewline();
                break;
            case 127:
            case ctrlKey('h'):
                backspace();
                break;
            case DEL_KEY:
                deleteChar();
                break;
            case HOME_KEY:
                cx_ = 0;
                break;
            case END_KEY:
                cx_ = static_cast<int>(rows_[cy_].size());
                break;
            case PAGE_UP:
            case PAGE_DOWN:
                pageMove(key == PAGE_DOWN);
                break;
            case ARROW_UP:
            case ARROW_DOWN:
            case ARROW_LEFT:
            case ARROW_RIGHT:
                moveCursor(key);
                break;
            case '\t':
                insertTab();
                break;
            case BACKTAB:
                outdentLine();
                break;
            default:
                if (key >= 32 && key < 127) insertChar(static_cast<char>(key));
                break;
        }
    }

    void quit() {
        if (dirty_ && quitConfirm_ > 0) {
            setStatus("Unsaved changes. Press Ctrl-Q again to quit.");
            --quitConfirm_;
            return;
        }
        stopRunner(false);
        running_ = false;
    }

    bool maybeDiscardDirty() {
        if (!dirty_) return true;
        return askYesNo("Discard unsaved changes? (y/n): ");
    }

    void openPrompt() {
        if (!maybeDiscardDirty()) return;
        auto path = prompt("Open file: ", filename_);
        if (path && !path->empty()) openFile(*path);
    }

    bool saveFile() {
        if (filename_.empty()) {
            auto path = prompt("Save as: ");
            if (!path || path->empty()) {
                setStatus("Save cancelled.");
                return false;
            }
            filename_ = expandPath(*path);
            language_ = detectLanguage(filename_, rows_);
            markHighlightDirty();
        }

        std::ofstream out(filename_);
        if (!out) {
            setStatus("Could not save: " + filename_);
            return false;
        }
        for (std::size_t i = 0; i < rows_.size(); ++i) {
            out << rows_[i];
            if (i + 1 < rows_.size()) out << '\n';
        }
        dirty_ = false;
        setStatus("Saved " + baseName(filename_));
        return true;
    }

    void cycleLanguage() {
        switch (language_) {
            case Language::SuperCollider: language_ = Language::ChucK; break;
            case Language::ChucK: language_ = Language::Cpp; break;
            case Language::Cpp: language_ = Language::Plain; break;
            case Language::Plain: language_ = Language::SuperCollider; break;
        }
        markHighlightDirty();
        setStatus("Language: " + languageName(language_));
    }

    void commandPalette() {
        auto cmd = prompt("Command: open save run stop search goto lang self help comment duplicate new quit > ");
        if (!cmd) return;
        std::string c = toLower(trim(*cmd));
        if (c.empty()) return;
        if (c == "open" || c == "o") openPrompt();
        else if (c == "save" || c == "write" || c == "w") saveFile();
        else if (c == "run" || c == "r") runBuffer();
        else if (c == "stop" || c == "t") stopRunner();
        else if (c == "search" || c == "find" || c == "f") searchPrompt();
        else if (c == "goto" || c == "line" || c == "j") gotoLinePrompt();
        else if (c == "lang" || c == "language" || c == "l") cycleLanguage();
        else if (c == "self" || c == "source" || c == "y") openSelfSource();
        else if (c == "help" || c == "?") showHelp_ = true;
        else if (c == "comment" || c == "/") toggleComment();
        else if (c == "duplicate" || c == "dup" || c == "d") duplicateLine();
        else if (c == "new") newBuffer();
        else if (c == "quit" || c == "q") quit();
        else setStatus("Unknown command: " + c);
    }

    void newBuffer() {
        if (!maybeDiscardDirty()) return;
        filename_.clear();
        rows_ = {""};
        language_ = Language::SuperCollider;
        dirty_ = false;
        cx_ = cy_ = rowoff_ = coloff_ = 0;
        searchTerm_.clear();
        markHighlightDirty();
        setStatus("New SuperCollider buffer.");
    }

    std::optional<std::string> prompt(const std::string& label, const std::string& initial = "") {
        promptActive_ = true;
        promptLabel_ = label;
        promptBuffer_ = initial;

        while (running_) {
            pollRunner();
            refreshScreen();
            int key = readKey();
            if (key == KEY_NULL) continue;
            if (key == '\x1b') {
                promptActive_ = false;
                promptLabel_.clear();
                promptBuffer_.clear();
                setStatus("Cancelled.");
                return std::nullopt;
            }
            if (key == '\r') {
                std::string result = promptBuffer_;
                promptActive_ = false;
                promptLabel_.clear();
                promptBuffer_.clear();
                return result;
            }
            if (key == 127 || key == ctrlKey('h') || key == DEL_KEY) {
                if (!promptBuffer_.empty()) promptBuffer_.pop_back();
            } else if (key >= 32 && key < 127) {
                promptBuffer_ += static_cast<char>(key);
            }
        }
        promptActive_ = false;
        return std::nullopt;
    }

    bool askYesNo(const std::string& message) {
        promptActive_ = true;
        promptLabel_ = message;
        promptBuffer_.clear();
        while (running_) {
            refreshScreen();
            int key = readKey();
            if (key == KEY_NULL) continue;
            promptActive_ = false;
            promptLabel_.clear();
            promptBuffer_.clear();
            if (key == 'y' || key == 'Y') return true;
            if (key == 'n' || key == 'N' || key == '\x1b') return false;
        }
        promptActive_ = false;
        return false;
    }

    void insertChar(char c) {
        if (c == '\t') {
            insertTab();
            return;
        }

        if (isCloseBracket(c) && cx_ < static_cast<int>(rows_[cy_].size()) && rows_[cy_][cx_] == c) {
            ++cx_;
            return;
        }

        char close = matchingBracket(c);
        if (close != '\0' && isOpenBracket(c)) {
            rows_[cy_].insert(cx_, std::string{c, close});
            ++cx_;
        } else if ((c == '"' || c == '\'') && shouldAutoPairQuote(c)) {
            rows_[cy_].insert(cx_, std::string{c, c});
            ++cx_;
        } else {
            rows_[cy_].insert(rows_[cy_].begin() + cx_, c);
            ++cx_;
        }
        dirty_ = true;
        markHighlightDirty();
    }

    bool shouldAutoPairQuote(char quote) const {
        if (cx_ > 0 && rows_[cy_][cx_ - 1] == '\\') return false;
        if (cx_ < static_cast<int>(rows_[cy_].size()) && rows_[cy_][cx_] == quote) return false;
        return true;
    }

    std::string leadingWhitespace(const std::string& line) const {
        std::size_t i = 0;
        while (i < line.size() && (line[i] == ' ' || line[i] == '\t')) ++i;
        return line.substr(0, i);
    }

    void insertNewline() {
        std::string& line = rows_[cy_];
        std::string left = line.substr(0, cx_);
        std::string right = line.substr(cx_);
        std::string indent = leadingWhitespace(left);
        bool bracketSandwich = !left.empty() && !right.empty() &&
            isOpenBracket(left.back()) && right.front() == matchingBracket(left.back());

        if (!left.empty() && std::strchr("{([", left.back()) != nullptr) {
            indent += "  ";
        }

        line = left;
        if (bracketSandwich) {
            std::string closeIndent = leadingWhitespace(left);
            rows_.insert(rows_.begin() + cy_ + 1, indent);
            rows_.insert(rows_.begin() + cy_ + 2, closeIndent + right);
        } else {
            rows_.insert(rows_.begin() + cy_ + 1, indent + right);
        }
        ++cy_;
        cx_ = static_cast<int>(indent.size());
        dirty_ = true;
        markHighlightDirty();
    }

    void insertTab() {
        int spaces = TAB_STOP - (rowCxToRx(cy_, cx_) % TAB_STOP);
        rows_[cy_].insert(cx_, std::string(spaces, ' '));
        cx_ += spaces;
        dirty_ = true;
        markHighlightDirty();
    }

    void outdentLine() {
        std::string& line = rows_[cy_];
        int removed = 0;
        while (removed < TAB_STOP && !line.empty() && line.front() == ' ') {
            line.erase(line.begin());
            ++removed;
        }
        if (removed > 0) {
            cx_ = std::max(0, cx_ - removed);
            dirty_ = true;
            markHighlightDirty();
        }
    }

    void backspace() {
        if (cy_ == 0 && cx_ == 0) return;
        std::string& line = rows_[cy_];
        if (cx_ > 0) {
            char before = line[cx_ - 1];
            if (isOpenBracket(before) && cx_ < static_cast<int>(line.size()) && line[cx_] == matchingBracket(before)) {
                line.erase(cx_ - 1, 2);
                --cx_;
            } else {
                line.erase(line.begin() + cx_ - 1);
                --cx_;
            }
        } else {
            cx_ = static_cast<int>(rows_[cy_ - 1].size());
            rows_[cy_ - 1] += line;
            rows_.erase(rows_.begin() + cy_);
            --cy_;
        }
        dirty_ = true;
        markHighlightDirty();
    }

    void deleteChar() {
        if (cy_ >= static_cast<int>(rows_.size())) return;
        std::string& line = rows_[cy_];
        if (cx_ < static_cast<int>(line.size())) {
            line.erase(line.begin() + cx_);
        } else if (cy_ + 1 < static_cast<int>(rows_.size())) {
            line += rows_[cy_ + 1];
            rows_.erase(rows_.begin() + cy_ + 1);
        } else {
            return;
        }
        dirty_ = true;
        markHighlightDirty();
    }

    void moveCursor(int key) {
        switch (key) {
            case ARROW_LEFT:
                if (cx_ > 0) --cx_;
                else if (cy_ > 0) {
                    --cy_;
                    cx_ = static_cast<int>(rows_[cy_].size());
                }
                break;
            case ARROW_RIGHT:
                if (cx_ < static_cast<int>(rows_[cy_].size())) ++cx_;
                else if (cy_ + 1 < static_cast<int>(rows_.size())) {
                    ++cy_;
                    cx_ = 0;
                }
                break;
            case ARROW_UP:
                if (cy_ > 0) --cy_;
                break;
            case ARROW_DOWN:
                if (cy_ + 1 < static_cast<int>(rows_.size())) ++cy_;
                break;
        }
        cx_ = std::min<int>(cx_, rows_[cy_].size());
    }

    void pageMove(bool down) {
        int times = contentRows_;
        while (times--) moveCursor(down ? ARROW_DOWN : ARROW_UP);
    }

    void duplicateLine() {
        rows_.insert(rows_.begin() + cy_ + 1, rows_[cy_]);
        ++cy_;
        dirty_ = true;
        markHighlightDirty();
        setStatus("Duplicated line.");
    }

    void toggleComment() {
        std::string& line = rows_[cy_];
        std::size_t indent = 0;
        while (indent < line.size() && std::isspace(static_cast<unsigned char>(line[indent]))) ++indent;
        if (line.compare(indent, 2, "//") == 0) {
            line.erase(indent, 2);
            if (cx_ >= static_cast<int>(indent + 2)) cx_ -= 2;
        } else {
            line.insert(indent, "//");
            if (cx_ >= static_cast<int>(indent)) cx_ += 2;
        }
        dirty_ = true;
        markHighlightDirty();
    }

    void searchPrompt() {
        auto term = prompt("Search: ", searchTerm_);
        if (!term) return;
        searchTerm_ = *term;
        if (searchTerm_.empty()) {
            setStatus("Search cleared.");
            return;
        }
        findNext(true, true);
    }

    void findNext(bool forward, bool fromCurrent = false) {
        if (searchTerm_.empty()) {
            setStatus("No search term. Ctrl-F starts search.");
            return;
        }
        int rowCount = static_cast<int>(rows_.size());
        int startRow = cy_;
        int startCol = fromCurrent ? cx_ : (forward ? cx_ + 1 : cx_ - 1);

        for (int step = 0; step < rowCount; ++step) {
            int row = forward ? (startRow + step) % rowCount : (startRow - step + rowCount) % rowCount;
            const std::string& line = rows_[row];
            if (forward) {
                std::size_t begin = (row == startRow) ? std::max(0, startCol) : 0;
                std::size_t pos = line.find(searchTerm_, begin);
                if (pos != std::string::npos) {
                    cy_ = row;
                    cx_ = static_cast<int>(pos);
                    setStatus("Found: " + searchTerm_);
                    return;
                }
            } else {
                std::size_t begin = (row == startRow && startCol >= 0)
                    ? static_cast<std::size_t>(std::min<int>(startCol, line.size()))
                    : std::string::npos;
                std::size_t pos = line.rfind(searchTerm_, begin);
                if (pos != std::string::npos) {
                    cy_ = row;
                    cx_ = static_cast<int>(pos);
                    setStatus("Found: " + searchTerm_);
                    return;
                }
            }
        }
        setStatus("No match: " + searchTerm_);
    }

    void gotoLinePrompt() {
        auto value = prompt("Go to line: ");
        if (!value || value->empty()) return;
        try {
            int line = std::stoi(*value);
            line = std::clamp(line, 1, static_cast<int>(rows_.size()));
            cy_ = line - 1;
            cx_ = std::min<int>(cx_, rows_[cy_].size());
        } catch (...) {
            setStatus("That is not a line number.");
        }
    }

    void updateBracketMatch() {
        matchA_.reset();
        matchB_.reset();
        if (rows_.empty()) return;

        int row = cy_;
        int col = cx_;
        char c = '\0';
        if (col < static_cast<int>(rows_[row].size()) &&
            (isOpenBracket(rows_[row][col]) || isCloseBracket(rows_[row][col]))) {
            c = rows_[row][col];
        } else if (col > 0 && (isOpenBracket(rows_[row][col - 1]) || isCloseBracket(rows_[row][col - 1]))) {
            --col;
            c = rows_[row][col];
        } else {
            return;
        }

        char target = matchingBracket(c);
        int direction = isOpenBracket(c) ? 1 : -1;
        int depth = 0;
        int r = row;
        int cc = col;
        while (true) {
            if (direction > 0) {
                ++cc;
                while (r < static_cast<int>(rows_.size())) {
                    const std::string& line = rows_[r];
                    while (cc < static_cast<int>(line.size())) {
                        char here = line[cc];
                        if (here == c) ++depth;
                        if (here == target) {
                            if (depth == 0) {
                                matchA_ = Position{row, col};
                                matchB_ = Position{r, cc};
                                return;
                            }
                            --depth;
                        }
                        ++cc;
                    }
                    ++r;
                    cc = 0;
                }
                return;
            } else {
                --cc;
                while (r >= 0) {
                    const std::string& line = rows_[r];
                    while (cc >= 0) {
                        char here = line[cc];
                        if (here == c) ++depth;
                        if (here == target) {
                            if (depth == 0) {
                                matchA_ = Position{row, col};
                                matchB_ = Position{r, cc};
                                return;
                            }
                            --depth;
                        }
                        --cc;
                    }
                    --r;
                    if (r >= 0) cc = static_cast<int>(rows_[r].size()) - 1;
                }
                return;
            }
        }
    }

    void runBuffer() {
        if (runnerPid_ > 0) {
            setStatus("A sketch is already running. Ctrl-T stops it.");
            return;
        }
        if (filename_.empty() || dirty_) {
            if (!saveFile()) return;
        }

        std::string exe;
        if (language_ == Language::SuperCollider) exe = "sclang";
        else if (language_ == Language::ChucK) exe = "chuck";
        else {
            setStatus("Run is configured for SuperCollider and ChucK buffers.");
            return;
        }

        if (!commandExists(exe)) {
            setStatus(exe + " was not found in PATH.");
            return;
        }

        std::string command = exe + " " + shellQuote(filename_);
        startRunner(command);
    }

    void startRunner(const std::string& command) {
        int pipefd[2];
        if (pipe(pipefd) == -1) {
            setStatus("Could not create runner pipe.");
            return;
        }

        pid_t pid = fork();
        if (pid == -1) {
            close(pipefd[0]);
            close(pipefd[1]);
            setStatus("Could not start runner.");
            return;
        }

        if (pid == 0) {
            close(pipefd[0]);
            dup2(pipefd[1], STDOUT_FILENO);
            dup2(pipefd[1], STDERR_FILENO);
            close(pipefd[1]);
            execl("/bin/sh", "sh", "-lc", command.c_str(), static_cast<char*>(nullptr));
            _exit(127);
        }

        close(pipefd[1]);
        fcntl(pipefd[0], F_SETFL, O_NONBLOCK);
        runnerPid_ = pid;
        runnerFd_ = pipefd[0];
        runnerPartial_.clear();
        appendConsole("$ " + command);
        setStatus("Running sketch. Ctrl-T stops it.");
    }

    void stopRunner(bool announce = true) {
        if (runnerPid_ <= 0) {
            if (announce) setStatus("No running sketch.");
            return;
        }
        kill(runnerPid_, SIGTERM);
        int status = 0;
        waitpid(runnerPid_, &status, 0);
        if (runnerFd_ != -1) {
            close(runnerFd_);
            runnerFd_ = -1;
        }
        runnerPid_ = -1;
        if (announce) {
            appendConsole("[stopped]");
            setStatus("Stopped sketch.");
        }
    }

    void pollRunner() {
        if (runnerFd_ != -1) {
            char buffer[512];
            while (true) {
                ssize_t n = read(runnerFd_, buffer, sizeof(buffer));
                if (n > 0) {
                    runnerPartial_.append(buffer, buffer + n);
                    flushRunnerLines(false);
                } else {
                    break;
                }
            }
        }

        if (runnerPid_ > 0) {
            int status = 0;
            pid_t result = waitpid(runnerPid_, &status, WNOHANG);
            if (result == runnerPid_) {
                flushRunnerLines(true);
                if (runnerFd_ != -1) {
                    close(runnerFd_);
                    runnerFd_ = -1;
                }
                runnerPid_ = -1;
                if (WIFEXITED(status)) {
                    appendConsole("[exit " + std::to_string(WEXITSTATUS(status)) + "]");
                } else if (WIFSIGNALED(status)) {
                    appendConsole("[signal " + std::to_string(WTERMSIG(status)) + "]");
                }
                setStatus("Runner finished.");
            }
        }
    }

    void flushRunnerLines(bool all) {
        std::size_t pos = 0;
        while ((pos = runnerPartial_.find('\n')) != std::string::npos) {
            std::string line = runnerPartial_.substr(0, pos);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            appendConsole(line);
            runnerPartial_.erase(0, pos + 1);
        }
        if (all && !runnerPartial_.empty()) {
            appendConsole(runnerPartial_);
            runnerPartial_.clear();
        }
    }

    void appendConsole(const std::string& line) {
        console_.push_back(line);
        if (console_.size() > 200) {
            console_.erase(console_.begin(), console_.begin() + static_cast<long>(console_.size() - 200));
        }
    }
};

void printUsage(const char* argv0) {
    std::cout
        << "SourCe " << JUICY_VERSION << "\n"
        << "Usage: " << argv0 << " [file]\n"
        << "       " << argv0 << " --self\n\n"
        << "A colorful terminal editor for SuperCollider and ChucK.\n";
}

} // namespace

int main(int argc, char** argv) {
    try {
        if (argc > 1) {
            std::string arg = argv[1];
            if (arg == "--help" || arg == "-h") {
                printUsage(argv[0]);
                return 0;
            }
            if (arg == "--version" || arg == "-v") {
                std::cout << JUICY_VERSION << "\n";
                return 0;
            }
        }

        Terminal terminal;
        terminal.enable();

        Editor editor;
        if (argc > 1 && std::string(argv[1]) == "--self") {
            editor.openSelfSource();
        } else if (argc > 1) {
            if (!editor.openFile(argv[1])) editor.loadWelcomeBuffer();
        } else {
            editor.loadWelcomeBuffer();
        }

        editor.loop();
        return 0;
    } catch (const std::exception& e) {
        Terminal::writeOut("\x1b[0m\x1b[?25h\x1b[?1049l");
        std::cerr << "SourCe: " << e.what() << "\n";
        return 1;
    }
}

