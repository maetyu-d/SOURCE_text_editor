#import <Cocoa/Cocoa.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <mach/mach.h>
#include <optional>
#include <sstream>
#include <string>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#include <unordered_set>
#include <vector>

namespace {

constexpr int TAB_STOP = 4;

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

enum class PromptMode {
    None,
    Search,
    Goto,
    Command
};

struct Position {
    int row = 0;
    int col = 0;
};

struct EditTrace {
    int row = 0;
    int col = 0;
    char ch = ' ';
    int frame = 0;
    bool deletion = false;
};

std::string cppString(NSString* value) {
    if (!value) return {};
    const char* utf8 = [value UTF8String];
    return utf8 ? std::string(utf8) : std::string();
}

NSString* nsString(const std::string& value) {
    NSString* result = [[NSString alloc] initWithBytes:value.data()
                                                length:value.size()
                                              encoding:NSUTF8StringEncoding];
    return result ? result : @"";
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

std::string baseName(const std::string& path) {
    if (path.empty()) return "Untitled";
    std::size_t slash = path.find_last_of('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

std::string expandPath(std::string path) {
    if (path == "~" || path.rfind("~/", 0) == 0) {
        if (const char* home = std::getenv("HOME")) return std::string(home) + path.substr(1);
    }
    return path;
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

uint64_t hashString(const std::string& value, uint64_t seed = 1469598103934665603ULL) {
    uint64_t h = seed;
    for (unsigned char c : value) {
        h ^= c;
        h *= 1099511628211ULL;
    }
    return h;
}

std::string formatBytes(uint64_t bytes) {
    const char* units[] = {"B", "KB", "MB", "GB"};
    double value = static_cast<double>(bytes);
    int unit = 0;
    while (value >= 1024.0 && unit < 3) {
        value /= 1024.0;
        ++unit;
    }
    std::ostringstream out;
    if (unit == 0) out << static_cast<uint64_t>(value);
    else out << std::fixed << std::setprecision(value >= 100.0 ? 0 : 1) << value;
    out << units[unit];
    return out.str();
}

int kindIndex(Kind kind) {
    return static_cast<int>(kind);
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

Language detectLanguage(const std::string& filename, const std::vector<std::string>& rows) {
    std::string lower = toLower(filename);
    if (endsWith(lower, ".scd") || endsWith(lower, ".sc")) return Language::SuperCollider;
    if (endsWith(lower, ".ck")) return Language::ChucK;
    if (endsWith(lower, ".cpp") || endsWith(lower, ".cc") || endsWith(lower, ".cxx") ||
        endsWith(lower, ".hpp") || endsWith(lower, ".hh") || endsWith(lower, ".h") ||
        endsWith(lower, ".mm") || endsWith(lower, ".m")) {
        return Language::Cpp;
    }
    for (const std::string& row : rows) {
        if (row.find("SynthDef") != std::string::npos || row.find("SinOsc.ar") != std::string::npos) {
            return Language::SuperCollider;
        }
        if (row.find("=>") != std::string::npos || row.find("::ms") != std::string::npos) {
            return Language::ChucK;
        }
    }
    return Language::Plain;
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
        "alignas", "alignof", "and", "asm", "auto", "bool", "break", "case",
        "catch", "char", "class", "const", "constexpr", "continue", "decltype",
        "default", "delete", "do", "double", "else", "enum", "explicit",
        "extern", "false", "float", "for", "friend", "if", "inline", "int",
        "long", "namespace", "new", "noexcept", "nullptr", "operator",
        "private", "protected", "public", "return", "short", "signed", "sizeof",
        "static", "struct", "switch", "template", "this", "throw", "true",
        "try", "typedef", "typename", "union", "unsigned", "using", "virtual",
        "void", "volatile", "while", "@interface", "@implementation", "@end",
        "@class", "@selector", "@autoreleasepool"
    };
    return words;
}

const std::unordered_set<std::string>& cppTypes() {
    static const std::unordered_set<std::string> words = {
        "std", "string", "vector", "array", "optional", "unordered_set",
        "size_t", "pid_t", "ifstream", "ofstream", "NSString", "NSView",
        "NSWindow", "NSColor", "NSFont", "NSEvent", "NSRect", "BOOL",
        "CGFloat", "NSInteger", "AppDelegate", "SourceTextView"
    };
    return words;
}

const std::unordered_set<std::string>& cppBuiltins() {
    static const std::unordered_set<std::string> words = {
        "read", "write", "close", "fork", "pipe", "dup2", "execl", "waitpid",
        "kill", "YES", "NO", "nil", "self", "super", "alloc", "init",
        "setNeedsDisplay", "drawAtPoint"
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

        if (lang == Language::Cpp && c == '@' && isIdentStart(next)) {
            std::size_t start = i++;
            while (i < n && isIdent(line[i])) ++i;
            markRange(kinds, start, i, classifyIdentifier(line.substr(start, i - start), lang));
            continue;
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
                if (escaped) escaped = false;
                else if (sc == '\\') escaped = true;
                else if (sc == quote) break;
            }
            markRange(kinds, start, i, Kind::String);
            continue;
        }

        if (lang == Language::SuperCollider && c == '\\' && i + 1 < n &&
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

} // namespace

@interface SourceTextView : NSView
@end

@implementation SourceTextView {
    std::vector<std::string> _rows;
    std::vector<std::vector<Kind>> _highlights;
    std::string _filename;
    Language _language;
    bool _dirty;
    bool _highlightDirty;
    int _cx;
    int _cy;
    int _rowoff;
    int _coloff;
    int _visibleRows;
    int _visibleCols;
    CGFloat _fontSize;
    CGFloat _charW;
    CGFloat _lineH;
    NSFont* _font;
    NSFont* _boldFont;
    std::string _status;
    std::string _searchTerm;
    std::optional<Position> _matchA;
    std::optional<Position> _matchB;
    PromptMode _promptMode;
    std::string _promptLabel;
    std::string _promptBuffer;
    NSTimer* _timer;
    double _pulse;
    pid_t _runnerPid;
    int _runnerFd;
    std::string _runnerPartial;
    std::vector<std::string> _console;
    NSImage* _feedbackImage;
    NSSize _feedbackSize;
    int _frame;
    bool _showProcessMap;
    int _tokenCount;
    int _visibleTokenCount;
    int _editCount;
    double _lastTickTime;
    double _lastDrawMs;
    double _cpuPercent;
    double _lastCpuSeconds;
    uint64_t _memoryFootprint;
    uint64_t _memoryVirtual;
    std::vector<uint64_t> _memorySamples;
    std::vector<EditTrace> _editTraces;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _language = Language::SuperCollider;
        _dirty = false;
        _highlightDirty = true;
        _cx = _cy = _rowoff = _coloff = 0;
        _visibleRows = 1;
        _visibleCols = 1;
        _fontSize = 22.0;
        _promptMode = PromptMode::None;
        _runnerPid = -1;
        _runnerFd = -1;
        _pulse = 0.0;
        _feedbackImage = nil;
        _feedbackSize = NSMakeSize(0, 0);
        _frame = 0;
        _showProcessMap = false;
        _tokenCount = 0;
        _visibleTokenCount = 0;
        _editCount = 0;
        _lastTickTime = [NSDate timeIntervalSinceReferenceDate];
        _lastDrawMs = 0.0;
        _cpuPercent = 0.0;
        _lastCpuSeconds = 0.0;
        _memoryFootprint = 0;
        _memoryVirtual = 0;
        [self refreshFont];
        [self sampleMemory];
        [self loadWelcome];
        [self setWantsLayer:YES];
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [[self window] makeFirstResponder:self];
    if (!_timer) {
        _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0
                                                  target:self
                                                selector:@selector(tick:)
                                                userInfo:nil
                                                 repeats:YES];
    }
}

- (void)dealloc {
    [self stopRunnerAnnounce:NO];
    [_timer invalidate];
}

- (void)refreshFont {
    _font = [NSFont fontWithName:@"SF Mono" size:_fontSize];
    if (!_font) _font = [NSFont fontWithName:@"SFNSMono" size:_fontSize];
    if (!_font) _font = [NSFont fontWithName:@"Menlo" size:_fontSize];
    if (!_font) _font = [NSFont userFixedPitchFontOfSize:_fontSize];
    _boldFont = [[NSFontManager sharedFontManager] convertFont:_font toHaveTrait:NSBoldFontMask];
    if (!_boldFont) _boldFont = _font;
    NSDictionary* attrs = @{NSFontAttributeName: _font};
    _charW = ceil([@"W" sizeWithAttributes:attrs].width);
    _lineH = ceil([_font ascender] - [_font descender] + 6.0);
}

- (void)loadWelcome {
    _filename.clear();
    _language = Language::SuperCollider;
    _rows = {
        "// Source TEXT: brightly colored live-code software art",
        "// Command-Y opens the C++/Objective-C++ source and highlights this highlighter.",
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
    _dirty = false;
    _cx = _cy = _rowoff = _coloff = 0;
    _searchTerm.clear();
    [self setStatus:"Ready."];
    [self markHighlightDirty];
    [self updateWindowTitle];
}

- (void)markHighlightDirty {
    _highlightDirty = true;
    [self setNeedsDisplay:YES];
}

- (void)setStatus:(const std::string&)message {
    _status = message;
    [self setNeedsDisplay:YES];
}

- (void)updateWindowTitle {
    std::string title = "Source TEXT - " + baseName(_filename);
    if (_dirty) title += " *";
    [[self window] setTitle:nsString(title)];
}

- (void)ensureHighlights {
    if (!_highlightDirty) return;
    _highlights.clear();
    _highlights.reserve(_rows.size());
    bool inBlock = false;
    int parenDepth = 0;
    _tokenCount = 0;
    for (const std::string& row : _rows) {
        std::vector<Kind> highlighted = highlightLine(row, _language, inBlock, parenDepth);
        Kind last = Kind::Normal;
        bool inToken = false;
        for (Kind kind : highlighted) {
            bool token = kind != Kind::Normal;
            if (token && (!inToken || kind != last)) ++_tokenCount;
            inToken = token;
            last = kind;
        }
        _highlights.push_back(std::move(highlighted));
    }
    _highlightDirty = false;
}

- (BOOL)loadFileAtPath:(NSString*)pathString {
    std::string path = expandPath(cppString(pathString));
    std::ifstream in(path);
    if (!in) {
        [self setStatus:"Could not open file."];
        return NO;
    }
    std::vector<std::string> loaded;
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        loaded.push_back(line);
    }
    if (loaded.empty()) loaded.push_back("");
    _rows = std::move(loaded);
    _filename = path;
    _language = detectLanguage(_filename, _rows);
    _dirty = false;
    _cx = _cy = _rowoff = _coloff = 0;
    _searchTerm.clear();
    [self markHighlightDirty];
    [self updateWindowTitle];
    [self setStatus:"Opened " + baseName(_filename) + " as " + languageName(_language) + "."];
    return YES;
}

- (BOOL)writeCurrentFile {
    if (_filename.empty()) {
        [self saveDocumentAs:nil];
        return NO;
    }
    std::ofstream out(_filename);
    if (!out) {
        [self setStatus:"Could not save file."];
        return NO;
    }
    for (std::size_t i = 0; i < _rows.size(); ++i) {
        out << _rows[i];
        if (i + 1 < _rows.size()) out << '\n';
    }
    _dirty = false;
    _language = detectLanguage(_filename, _rows);
    [self markHighlightDirty];
    [self updateWindowTitle];
    [self setStatus:"Saved " + baseName(_filename) + "."];
    return YES;
}

- (BOOL)confirmDiscard {
    if (!_dirty) return YES;
    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Discard unsaved changes?"];
    [alert setInformativeText:@"The current buffer has edits that have not been saved."];
    [alert addButtonWithTitle:@"Discard"];
    [alert addButtonWithTitle:@"Cancel"];
    return [alert runModal] == NSAlertFirstButtonReturn;
}

- (void)openDocument:(id)sender {
    (void)sender;
    if (![self confirmDiscard]) return;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [panel setAllowedFileTypes:@[@"scd", @"sc", @"ck", @"cpp", @"hpp", @"h", @"mm", @"m", @"txt"]];
#pragma clang diagnostic pop
    [panel beginSheetModalForWindow:[self window] completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) [self loadFileAtPath:[[panel URL] path]];
    }];
}

- (void)saveDocument:(id)sender {
    (void)sender;
    if (_filename.empty()) [self saveDocumentAs:nil];
    else [self writeCurrentFile];
}

- (void)saveDocumentAs:(id)sender {
    (void)sender;
    NSSavePanel* panel = [NSSavePanel savePanel];
    [panel setNameFieldStringValue:nsString(baseName(_filename.empty() ? "untitled.scd" : _filename))];
    [panel beginSheetModalForWindow:[self window] completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            _filename = cppString([[panel URL] path]);
            [self writeCurrentFile];
        }
    }];
}

- (void)openSelf:(id)sender {
    (void)sender;
    if (![self confirmDiscard]) return;
    [self loadFileAtPath:nsString(JUICY_SOURCE_PATH)];
    _language = Language::Cpp;
    [self markHighlightDirty];
    [self setStatus:"Self-highlight mode: the editor is coloring its own source."];
}

- (void)showFind:(id)sender {
    (void)sender;
    [self beginPrompt:PromptMode::Search label:"Find: " initial:_searchTerm];
}

- (void)showCommand:(id)sender {
    (void)sender;
    [self beginPrompt:PromptMode::Command label:"Command: " initial:""];
}

- (void)newDocument:(id)sender {
    (void)sender;
    if (![self confirmDiscard]) return;
    _filename.clear();
    _rows = {""};
    _language = Language::SuperCollider;
    _dirty = false;
    _cx = _cy = _rowoff = _coloff = 0;
    [self markHighlightDirty];
    [self updateWindowTitle];
}

- (void)runDocument:(id)sender {
    (void)sender;
    [self runBuffer];
}

- (void)stopRun:(id)sender {
    (void)sender;
    [self stopRunnerAnnounce:YES];
}

- (void)toggleHelp:(id)sender {
    (void)sender;
    [self beginPrompt:PromptMode::Command label:"Try: open save run stop search goto lang self process comment duplicate new  > " initial:""];
}

- (int)rowCxToRx:(int)row cx:(int)cx {
    if (row < 0 || row >= static_cast<int>(_rows.size())) return 0;
    const std::string& line = _rows[row];
    int rx = 0;
    int limit = std::min<int>(cx, line.size());
    for (int i = 0; i < limit; ++i) {
        if (line[i] == '\t') rx += TAB_STOP - (rx % TAB_STOP);
        else ++rx;
    }
    return rx;
}

- (void)scrollToCursor {
    _cy = std::clamp(_cy, 0, std::max(0, static_cast<int>(_rows.size()) - 1));
    _cx = std::clamp(_cx, 0, static_cast<int>(_rows[_cy].size()));
    if (_cy < _rowoff) _rowoff = _cy;
    if (_cy >= _rowoff + _visibleRows) _rowoff = _cy - _visibleRows + 1;
    int rx = [self rowCxToRx:_cy cx:_cx];
    if (rx < _coloff) _coloff = rx;
    if (rx >= _coloff + _visibleCols) _coloff = rx - _visibleCols + 1;
    _rowoff = std::max(0, _rowoff);
    _coloff = std::max(0, _coloff);
}

- (void)sampleMemory {
    task_vm_info_data_t vmInfo{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(),
                                     TASK_VM_INFO,
                                     reinterpret_cast<task_info_t>(&vmInfo),
                                     &count);
    if (result == KERN_SUCCESS) {
        _memoryFootprint = static_cast<uint64_t>(vmInfo.phys_footprint);
        _memoryVirtual = static_cast<uint64_t>(vmInfo.virtual_size);
        _memorySamples.push_back(_memoryFootprint);
        if (_memorySamples.size() > 220) {
            _memorySamples.erase(_memorySamples.begin(),
                                 _memorySamples.begin() + static_cast<long>(_memorySamples.size() - 220));
        }
    }
}

- (void)sampleCpuWithDelta:(double)delta {
    rusage usage{};
    if (getrusage(RUSAGE_SELF, &usage) != 0) return;
    double cpuSeconds =
        usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1000000.0 +
        usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1000000.0;
    if (_lastCpuSeconds > 0.0 && delta > 0.0) {
        double instant = ((cpuSeconds - _lastCpuSeconds) / delta) * 100.0;
        _cpuPercent = _cpuPercent * 0.82 + instant * 0.18;
    }
    _lastCpuSeconds = cpuSeconds;
}

- (void)updateVisibleTokenCount {
    _visibleTokenCount = 0;
    int endRow = std::min<int>(_rows.size(), _rowoff + _visibleRows);
    for (int row = _rowoff; row < endRow && row < static_cast<int>(_highlights.size()); ++row) {
        Kind last = Kind::Normal;
        bool inToken = false;
        for (Kind kind : _highlights[row]) {
            bool token = kind != Kind::Normal;
            if (token && (!inToken || kind != last)) ++_visibleTokenCount;
            inToken = token;
            last = kind;
        }
    }
}

- (bool)isSelfSource {
    return !_filename.empty() && _filename == std::string(JUICY_SOURCE_PATH);
}

- (void)recordEditAtRow:(int)row col:(int)col ch:(char)ch deletion:(BOOL)deletion {
    _editTraces.push_back(EditTrace{row, col, ch, _frame, deletion != NO});
    if (_editTraces.size() > 260) {
        _editTraces.erase(_editTraces.begin(),
                          _editTraces.begin() + static_cast<long>(_editTraces.size() - 260));
    }
    ++_editCount;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    double drawStart = [NSDate timeIntervalSinceReferenceDate];
    [self ensureHighlights];
    [self updateBracketMatch];

    NSRect bounds = [self bounds];
    [[NSColor colorWithCalibratedRed:0.025 green:0.020 blue:0.120 alpha:1.0] setFill];
    NSRectFill(bounds);

    CGFloat topH = 48.0;
    CGFloat statusH = 34.0;
    CGFloat promptH = (_promptMode == PromptMode::None) ? 0.0 : 40.0;
    CGFloat consoleH = (_console.empty() && _runnerPid <= 0) ? 0.0 : std::min<CGFloat>(130.0, bounds.size.height * 0.25);
    CGFloat minimapW = 76.0;
    CGFloat gutterW = std::max<CGFloat>(54.0, (std::to_string(std::max<std::size_t>(1, _rows.size())).size() + 2) * _charW);
    CGFloat editorH = std::max<CGFloat>(1.0, bounds.size.height - topH - statusH - promptH - consoleH);
    CGFloat editorW = std::max<CGFloat>(1.0, bounds.size.width - gutterW - minimapW - 12.0);
    _visibleRows = std::max(1, static_cast<int>(floor(editorH / _lineH)));
    _visibleCols = std::max(1, static_cast<int>(floor(editorW / _charW)));
    [self scrollToCursor];
    [self updateVisibleTokenCount];

    NSRect codeRect = NSMakeRect(0, topH, bounds.size.width - minimapW, editorH);
    [self updateFeedbackLayer:bounds codeRect:codeRect gutter:gutterW];

    [self drawArtBackdrop:bounds];
    [self drawMemoryMap:NSMakeRect(0, topH, bounds.size.width - minimapW, editorH)];
    [self drawTopBar:NSMakeRect(0, 0, bounds.size.width, topH)];
    [self drawCodeArea:codeRect gutter:gutterW];
    [self drawMinimap:NSMakeRect(bounds.size.width - minimapW, topH, minimapW, editorH)];
    if (consoleH > 0) [self drawConsole:NSMakeRect(0, topH + editorH, bounds.size.width, consoleH)];
    [self drawStatus:NSMakeRect(0, bounds.size.height - statusH - promptH, bounds.size.width, statusH)];
    if (_promptMode != PromptMode::None) [self drawPrompt:NSMakeRect(0, bounds.size.height - promptH, bounds.size.width, promptH)];
    if (_showProcessMap) [self drawProcessMap:codeRect];
    _lastDrawMs = ([NSDate timeIntervalSinceReferenceDate] - drawStart) * 1000.0;
}

- (NSColor*)colorForKind:(Kind)kind row:(int)row col:(int)col background:(BOOL)background active:(BOOL)active {
    CGFloat waveA = sin(row * 0.37 + col * 0.17 + _pulse * 1.65);
    CGFloat waveB = sin(row * 0.13 - col * 0.31 + _pulse * 2.20);
    CGFloat waveC = sin(row * 0.53 + _pulse * 1.10);
    int slabX = static_cast<int>(floor((col + waveA * 5.5 + _pulse * 10.0) / 7.0));
    int slabY = static_cast<int>(floor((row + waveB * 4.0 - _pulse * 4.0) / 5.0));
    int slab = ((slabX * 3 + slabY * 5) % 9 + 9) % 9;
    BOOL hotSlab = slab == 0 || slab == 4;
    BOOL coolSlab = slab == 2 || slab == 6;
    BOOL darkChannel = waveA + waveB + waveC > 2.15;
    CGFloat jitter = fmod((row * 29 + col * 17) * 0.007 + _pulse * 0.020, 0.09);
    CGFloat hue = 0.64;
    CGFloat sat = 0.78;
    CGFloat bri = background ? 0.24 : 0.93;
    CGFloat alpha = background ? 1.0 : 1.0;

    switch (kind) {
        case Kind::Comment: hue = 0.42; sat = 0.78; bri = background ? 0.38 : 0.95; break;
        case Kind::Keyword: hue = 0.88; sat = 0.84; bri = background ? 0.62 : 1.00; break;
        case Kind::Type: hue = 0.52; sat = 0.82; bri = background ? 0.58 : 1.00; break;
        case Kind::Builtin: hue = 0.13; sat = 0.92; bri = background ? 0.76 : 1.00; break;
        case Kind::Number: hue = 0.05; sat = 0.88; bri = background ? 0.70 : 1.00; break;
        case Kind::String: hue = 0.34; sat = 0.78; bri = background ? 0.56 : 1.00; break;
        case Kind::Symbol: hue = 0.10; sat = 0.92; bri = background ? 0.72 : 1.00; break;
        case Kind::Operator: hue = 0.72; sat = 0.72; bri = background ? 0.52 : 1.00; break;
        case Kind::Preprocessor: hue = 0.78; sat = 0.72; bri = background ? 0.64 : 1.00; break;
        case Kind::Search: hue = 0.15; sat = 0.98; bri = background ? 0.98 : 0.12; break;
        case Kind::Match: hue = 0.96; sat = 0.96; bri = background ? 0.92 : 1.00; break;
        case Kind::Paren0: hue = 0.91; sat = 0.86; bri = background ? 0.58 : 1.00; break;
        case Kind::Paren1: hue = 0.54; sat = 0.86; bri = background ? 0.58 : 1.00; break;
        case Kind::Paren2: hue = 0.15; sat = 0.95; bri = background ? 0.74 : 1.00; break;
        case Kind::Paren3: hue = 0.36; sat = 0.84; bri = background ? 0.58 : 1.00; break;
        case Kind::Paren4: hue = 0.04; sat = 0.88; bri = background ? 0.66 : 1.00; break;
        case Kind::Paren5: hue = 0.76; sat = 0.82; bri = background ? 0.62 : 1.00; break;
        case Kind::Normal:
        default:
            hue = 0.63 + jitter;
            sat = 0.64;
            bri = background ? 0.26 : 0.74;
            break;
    }

    if (background) {
        if (hotSlab) {
            hue = fmod(0.92 + slab * 0.047 + jitter, 1.0);
            sat = std::max<CGFloat>(sat, 0.88);
            bri = std::max<CGFloat>(bri, kind == Kind::Normal ? 0.56 : 0.82);
        } else if (coolSlab) {
            hue = fmod(0.50 + slab * 0.033 + jitter, 1.0);
            sat = std::max<CGFloat>(sat, 0.76);
            bri = std::max<CGFloat>(bri, kind == Kind::Normal ? 0.52 : 0.74);
        } else if (darkChannel) {
            hue = 0.66 + jitter;
            sat = 0.78;
            bri = kind == Kind::Normal ? 0.15 : std::max<CGFloat>(0.34, bri - 0.18);
        }
        if (active) bri = std::min<CGFloat>(1.0, bri + 0.10);
    } else {
        BOOL brightCell = hotSlab || coolSlab || kind == Kind::Search ||
            kind == Kind::Builtin || kind == Kind::Number || kind == Kind::Symbol;
        if (brightCell && !darkChannel) {
            hue = 0.67;
            sat = 0.82;
            bri = 0.12;
        }
    }
    return [NSColor colorWithCalibratedHue:fmod(hue + jitter, 1.0)
                                saturation:sat
                                brightness:bri
                                     alpha:alpha];
}

- (void)updateFeedbackLayer:(NSRect)bounds codeRect:(NSRect)codeRect gutter:(CGFloat)gutterW {
    if (bounds.size.width < 2 || bounds.size.height < 2) return;

    BOOL sameSize = _feedbackImage &&
        fabs(_feedbackSize.width - bounds.size.width) < 0.5 &&
        fabs(_feedbackSize.height - bounds.size.height) < 0.5;
    NSImage* previous = sameSize ? [_feedbackImage copy] : nil;
    _feedbackSize = bounds.size;
    _feedbackImage = [[NSImage alloc] initWithSize:_feedbackSize];

    struct Step {
        CGFloat x;
        CGFloat y;
    };
    std::array<Step, 8> directions{{
        {_charW, 0.0},
        {_charW, _lineH},
        {0.0, _lineH},
        {-_charW, _lineH},
        {-_charW, 0.0},
        {-_charW, -_lineH},
        {0.0, -_lineH},
        {_charW, -_lineH}
    }};

    uint64_t visibleHash = hashString(_filename, static_cast<uint64_t>(_language) + 1);
    int endRow = std::min<int>(_rows.size(), _rowoff + _visibleRows);
    for (int row = _rowoff; row < endRow; ++row) {
        visibleHash = hashString(_rows[row], visibleHash ^ static_cast<uint64_t>(row + 1));
    }
    if (!_console.empty()) {
        visibleHash = hashString(_console.back(), visibleHash ^ static_cast<uint64_t>(_console.size() * 131));
    }
    visibleHash ^= (_memoryFootprint >> 4);
    visibleHash ^= (_memoryVirtual << 3);
    visibleHash ^= static_cast<uint64_t>(_dirty ? 0xD17E : 0x5A7E);
    visibleHash ^= static_cast<uint64_t>(_runnerPid > 0 ? 0xA0D10 : 0xC0DE);

    int dirIndex = static_cast<int>(((visibleHash >> 7) + _frame / 10) % directions.size());
    Step primary = directions[dirIndex];
    Step secondary = directions[(dirIndex + 2) % static_cast<int>(directions.size())];
    NSRect full = NSMakeRect(0, 0, _feedbackSize.width, _feedbackSize.height);

    [_feedbackImage lockFocusFlipped:YES];
    [[NSColor clearColor] setFill];
    NSRectFillUsingOperation(full, NSCompositingOperationCopy);

    if (previous) {
        [previous drawInRect:NSOffsetRect(full, primary.x, primary.y)
                    fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver
                    fraction:0.74
              respectFlipped:YES
                       hints:nil];
        [previous drawInRect:NSOffsetRect(full, secondary.x * 1.6, secondary.y * 1.6)
                    fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver
                    fraction:0.24
              respectFlipped:YES
                       hints:nil];
    }

    [[NSColor colorWithCalibratedRed:0.01 green:0.01 blue:0.05 alpha:0.12] setFill];
    NSRectFillUsingOperation(full, NSCompositingOperationSourceOver);

    [NSGraphicsContext saveGraphicsState];
    [NSBezierPath clipRect:codeRect];

    CGFloat codeX = codeRect.origin.x + gutterW;

    for (int y = 0; y < _visibleRows; ++y) {
        int row = _rowoff + y;
        if (row >= static_cast<int>(_rows.size())) continue;
        const std::string& line = _rows[row];
        uint64_t lineHash = hashString(line, visibleHash ^ static_cast<uint64_t>(row * 977));
        CGFloat lineY = codeRect.origin.y + y * _lineH;

        std::vector<Kind> kinds = (row < static_cast<int>(_highlights.size()))
            ? _highlights[row]
            : std::vector<Kind>(line.size(), Kind::Normal);
        [self overlaySearch:kinds line:line];
        [self overlayBracketMatches:kinds row:row];

        int tokenRuns = 0;
        int bracketBalance = 0;
        Kind lastKind = Kind::Normal;
        for (std::size_t i = 0; i < line.size(); ++i) {
            Kind here = i < kinds.size() ? kinds[i] : Kind::Normal;
            if (i == 0 || here != lastKind) ++tokenRuns;
            if (isOpenBracket(line[i])) ++bracketBalance;
            if (isCloseBracket(line[i])) --bracketBalance;
            lastKind = here;
        }

        for (int layer = 0; layer < 3; ++layer) {
            int phase = _frame / std::max(2, 6 - layer);
            int stride = 5 + static_cast<int>((lineHash >> (layer * 7)) % 11);
            int offset = static_cast<int>((lineHash >> (11 + layer * 9)) % std::max(1, stride));
            Step step = directions[(dirIndex + layer + std::abs(bracketBalance) + tokenRuns) % static_cast<int>(directions.size())];
            for (int col = -offset; col < std::min(_visibleCols, static_cast<int>(line.size()) - _coloff); col += stride) {
                int sourceCol = _coloff + std::max(0, col);
                if (sourceCol >= static_cast<int>(line.size())) continue;
                unsigned char byte = static_cast<unsigned char>(line[sourceCol]);
                if (std::isspace(byte)) continue;
                Kind kind = sourceCol < static_cast<int>(kinds.size()) ? kinds[sourceCol] : Kind::Normal;
                int drift = ((phase + byte + kindIndex(kind) * 3 + tokenRuns) % (stride + 5)) - stride / 2;
                CGFloat x = codeX + (col + drift) * _charW + step.x * layer;
                CGFloat w = (2 + (byte % 7)) * _charW;
                CGFloat h = _lineH * (1.0 + ((byte + layer) % 3 == 0 ? 0.95 : 0.0));
                NSColor* base = [self colorForKind:kind row:row col:sourceCol background:YES active:NO];
                CGFloat alpha = 0.08 + 0.025 * layer + std::min(0.12, tokenRuns * 0.003);
                [[base colorWithAlphaComponent:alpha] setFill];
                NSRectFillUsingOperation(NSMakeRect(x, lineY + step.y * 0.22 * layer, w, h),
                                         NSCompositingOperationSourceOver);

                int glyphCount = std::min<int>(18, std::max<int>(3, w / (_charW * 0.55)));
                std::string glyphs;
                glyphs.reserve(static_cast<std::size_t>(glyphCount));
                int glyphStep = 1 + static_cast<int>((lineHash >> (layer * 5 + 3)) % 5);
                for (int g = 0; g < glyphCount; ++g) {
                    char gc = line[(sourceCol + g * glyphStep) % line.size()];
                    if (!std::isprint(static_cast<unsigned char>(gc)) || gc == ' ') {
                        gc = "{}[]()+-=*/<>;:.,|"[(byte + g + layer) % 18];
                    }
                    glyphs += gc;
                }
                NSFont* trailFont = [NSFont monospacedSystemFontOfSize:std::max<CGFloat>(8.0, _fontSize * (0.42 + layer * 0.04))
                                                                 weight:NSFontWeightBold];
                NSColor* glyphColor = [NSColor colorWithCalibratedHue:fmod(0.66 + byte / 255.0, 1.0)
                                                            saturation:0.34
                                                            brightness:0.98
                                                                 alpha:0.24 + layer * 0.07];
                NSDictionary* attrs = @{NSFontAttributeName: trailFont,
                                        NSForegroundColorAttributeName: glyphColor};
                [nsString(glyphs) drawAtPoint:NSMakePoint(x + 1.0, lineY + step.y * 0.22 * layer - 3.0)
                                withAttributes:attrs];
            }
        }

        int rx = 0;
        for (std::size_t i = 0; i < line.size(); ++i) {
            char c = line[i];
            int width = (c == '\t') ? (TAB_STOP - (rx % TAB_STOP)) : 1;
            Kind kind = i < kinds.size() ? kinds[i] : Kind::Normal;
            for (int w = 0; w < width; ++w) {
                if (rx >= _coloff && rx < _coloff + _visibleCols) {
                    int visualCol = rx - _coloff;
                    uint64_t cellHash = lineHash ^ (static_cast<uint64_t>(rx + 1) * 11400714819323198485ULL);
                    int gate = static_cast<int>((cellHash + _frame * (3 + kindIndex(kind))) % 53);
                    BOOL syntaxCell = kind != Kind::Normal && kind != Kind::Comment;
                    BOOL structuralCell = isOpenBracket(c) || isCloseBracket(c) || std::strchr("+-*/%=<>|&", c) != nullptr;
                    int memoryHeat = static_cast<int>((_memoryFootprint >> 20) % 7);
                    BOOL movingCell = gate < (syntaxCell ? 18 + memoryHeat : 4 + memoryHeat / 2) ||
                        (structuralCell && gate < 31 + memoryHeat);
                    if (movingCell) {
                        int trailDir = static_cast<int>((dirIndex + kindIndex(kind) + c + bracketBalance) % directions.size());
                        if (trailDir < 0) trailDir += static_cast<int>(directions.size());
                        Step trail = directions[trailDir];
                        int length = 2 + static_cast<int>((cellHash >> 9) % (structuralCell ? 9 : 6));
                        CGFloat x = codeX + visualCol * _charW;
                        for (int t = 0; t < length; ++t) {
                            CGFloat fade = (syntaxCell ? 0.36 : 0.16) * (1.0 - static_cast<CGFloat>(t) / (length + 1));
                            NSColor* base = [self colorForKind:kind row:row col:rx background:YES active:NO];
                            NSColor* color = [base colorWithAlphaComponent:fade];
                            [color setFill];
                            CGFloat widthCells = _charW * (1.0 + ((c + t) % 3 == 0 ? 1.0 : 0.0));
                            NSRectFillUsingOperation(NSMakeRect(x + trail.x * t * 0.85,
                                                                lineY + trail.y * t * 0.85,
                                                                widthCells + 1.0,
                                                                _lineH),
                                                     NSCompositingOperationSourceOver);
                        }
                    }
                }
                ++rx;
            }
        }
    }

    [NSGraphicsContext restoreGraphicsState];
    [_feedbackImage unlockFocus];
}

- (void)drawArtBackdrop:(NSRect)bounds {
    if (_rows.empty()) return;

    uint64_t programHash = hashString(_filename, 0x50A7CEULL);
    programHash = hashString(languageName(_language), programHash);
    int endRow = std::min<int>(_rows.size(), _rowoff + _visibleRows);
    for (int row = _rowoff; row < endRow; ++row) {
        programHash = hashString(_rows[row], programHash ^ static_cast<uint64_t>(row + 1));
    }
    if (!_console.empty()) programHash = hashString(_console.back(), programHash);

    CGFloat top = 48.0;
    CGFloat availableH = std::max<CGFloat>(1.0, bounds.size.height - top - 34.0);
    CGFloat codeW = std::max<CGFloat>(1.0, bounds.size.width - 76.0);
    int rowsToDraw = std::max(1, endRow - _rowoff);

    NSDictionary* smallAttrsBase = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:std::max<CGFloat>(9.0, _fontSize * 0.54)
                                                                                       weight:NSFontWeightBold]};
    for (int row = _rowoff; row < endRow; ++row) {
        const std::string& line = _rows[row];
        if (line.empty()) continue;
        uint64_t lineHash = hashString(line, programHash ^ static_cast<uint64_t>(row * 4099));
        CGFloat y = top + (row - _rowoff) * (availableH / rowsToDraw);

        int openCount = 0;
        int operators = 0;
        int letters = 0;
        for (char c : line) {
            if (isOpenBracket(c)) ++openCount;
            if (std::strchr("+-*/%=<>|&", c) != nullptr) ++operators;
            if (isIdent(c)) ++letters;
        }

        int slabs = std::clamp<int>(1 + operators / 3 + openCount, 1, 9);
        for (int s = 0; s < slabs; ++s) {
            uint64_t h = hashString(line.substr(0, std::min<std::size_t>(line.size(), s * 7 + 1)),
                                    lineHash ^ static_cast<uint64_t>(s * 7919));
            CGFloat x = fmod(static_cast<CGFloat>((h >> 11) % 10000) / 10000.0 * codeW +
                             (_frame % 64) * ((h & 1ULL) ? _charW : -_charW), codeW + 180.0) - 90.0;
            CGFloat w = (3 + static_cast<int>((h >> 23) % 11) + letters % 5) * _charW;
            CGFloat hgt = (1 + static_cast<int>((h >> 29) % 4)) * (_lineH * 0.42);
            CGFloat hue = fmod(0.50 + ((h >> 37) % 360) / 360.0 + (_dirty ? 0.06 : 0.0), 1.0);
            CGFloat alpha = 0.045 + std::min<CGFloat>(0.10, (operators + openCount) * 0.008);
            if (_runnerPid > 0) alpha += 0.035;
            NSColor* color = [NSColor colorWithCalibratedHue:hue saturation:0.88 brightness:0.72 alpha:alpha];
            [color setFill];
            NSRectFillUsingOperation(NSMakeRect(x, y + s * 2.0, w, hgt), NSCompositingOperationSourceOver);
        }

        int scanlines = std::clamp<int>(2 + static_cast<int>(lineHash % 7) + operators / 2, 3, 14);
        for (int s = 0; s < scanlines; ++s) {
            uint64_t h = lineHash ^ (static_cast<uint64_t>(s + 1) * 0x9E3779B185EBCA87ULL);
            CGFloat baseY = y + fmod(static_cast<CGFloat>((h >> 6) % 1000) / 1000.0 * _lineH * 0.95 +
                                     (_frame % 11) * 0.33, std::max<CGFloat>(1.0, _lineH));
            CGFloat x = fmod(static_cast<CGFloat>((h >> 17) % 10000) / 10000.0 * (codeW + 260.0) -
                             120.0 + (_frame % 96) * (((h >> 3) & 1ULL) ? 1.0 : -1.0) * (_charW * 0.36),
                             codeW + 260.0) - 130.0;
            int stripeChars = std::clamp<int>(4 + static_cast<int>((h >> 29) % 28) + operators, 5, 42);
            CGFloat stripeW = stripeChars * (_charW * 0.52);
            CGFloat hue = fmod(0.58 + ((h >> 38) % 360) / 360.0 + kindIndex(classifyIdentifier(line.substr(0, std::min<std::size_t>(line.size(), 8)), _language)) * 0.019, 1.0);
            CGFloat bright = 0.60 + ((h >> 44) % 35) / 100.0;
            CGFloat alpha = 0.12 + std::min<CGFloat>(0.14, (operators + openCount + letters / 12) * 0.006);
            NSColor* stripe = [NSColor colorWithCalibratedHue:hue saturation:0.98 brightness:bright alpha:alpha];
            [stripe setFill];
            NSRect stripeRect = NSMakeRect(x, baseY, stripeW, std::max<CGFloat>(2.0, _lineH * (0.10 + ((h >> 9) % 4) * 0.035)));
            NSRectFillUsingOperation(stripeRect, NSCompositingOperationSourceOver);

            if (((h >> 12) & 3ULL) != 0) {
                NSMutableDictionary* attrs = [smallAttrsBase mutableCopy];
                BOOL darkGlyphs = bright > 0.78 || (((h >> 5) & 1ULL) != 0);
                attrs[NSForegroundColorAttributeName] = darkGlyphs
                    ? [NSColor colorWithCalibratedRed:0.03 green:0.02 blue:0.10 alpha:0.78]
                    : [[NSColor colorWithCalibratedHue:fmod(hue + 0.50, 1.0)
                                            saturation:0.35
                                            brightness:1.0
                                                 alpha:0.82] copy];

                std::string glyphs;
                glyphs.reserve(static_cast<std::size_t>(stripeChars));
                int start = static_cast<int>((h >> 20) % line.size());
                int step = 1 + static_cast<int>((h >> 25) % 5);
                for (int g = 0; g < stripeChars; ++g) {
                    char c = line[(start + g * step) % line.size()];
                    if (!std::isprint(static_cast<unsigned char>(c)) || c == ' ') {
                        c = "[]{}()+-=*/<>|&;:.,\\"[(h + g) % 20];
                    }
                    glyphs += c;
                }
                [nsString(glyphs) drawAtPoint:NSMakePoint(x + 1.0, baseY - 5.0) withAttributes:attrs];
            }
        }
    }
}

- (void)drawMemoryMap:(NSRect)rect {
    if (_memorySamples.empty()) return;

    uint64_t minSample = *std::min_element(_memorySamples.begin(), _memorySamples.end());
    uint64_t maxSample = *std::max_element(_memorySamples.begin(), _memorySamples.end());
    uint64_t span = std::max<uint64_t>(1, maxSample - minSample);
    CGFloat panelH = std::min<CGFloat>(150.0, std::max<CGFloat>(72.0, rect.size.height * 0.20));
    CGFloat panelY = rect.origin.y + rect.size.height - panelH - 10.0;
    CGFloat rightPad = 18.0;
    CGFloat panelW = std::min<CGFloat>(rect.size.width - 24.0, std::max<CGFloat>(360.0, rect.size.width * 0.55));
    CGFloat panelX = rect.origin.x + rect.size.width - panelW - rightPad;

    [[NSColor colorWithCalibratedRed:0.02 green:0.015 blue:0.08 alpha:0.16] setFill];
    NSRectFillUsingOperation(NSMakeRect(panelX, panelY, panelW, panelH), NSCompositingOperationSourceOver);

    std::size_t n = _memorySamples.size();
    CGFloat colW = std::max<CGFloat>(2.0, panelW / std::max<std::size_t>(1, n));
    NSDictionary* glyphAttrs = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightBold]};
    const char* hex = "0123456789ABCDEF";

    for (std::size_t i = 0; i < n; ++i) {
        uint64_t sample = _memorySamples[i];
        CGFloat ratio = static_cast<CGFloat>(sample - minSample) / static_cast<CGFloat>(span);
        CGFloat x = panelX + i * colW;
        CGFloat h = 4.0 + ratio * (panelH - 20.0);
        CGFloat y = panelY + panelH - h;
        CGFloat hue = fmod(0.48 + ratio * 0.42 + ((sample >> 18) & 15) / 64.0, 1.0);
        NSColor* bar = [NSColor colorWithCalibratedHue:hue saturation:0.95 brightness:0.95 alpha:0.26];
        [bar setFill];
        NSRectFillUsingOperation(NSMakeRect(x, y, colW + 1.0, h), NSCompositingOperationSourceOver);

        if (colW > 3.2 || (i % 3 == 0)) {
            char chars[5] = {
                hex[(sample >> 12) & 0xF],
                hex[(sample >> 20) & 0xF],
                hex[(sample >> 28) & 0xF],
                hex[(sample >> 36) & 0xF],
                '\0'
            };
            NSMutableDictionary* attrs = [glyphAttrs mutableCopy];
            attrs[NSForegroundColorAttributeName] = [NSColor colorWithCalibratedHue:fmod(hue + 0.50, 1.0)
                                                                         saturation:0.38
                                                                         brightness:1.0
                                                                              alpha:0.38];
            [nsString(chars) drawAtPoint:NSMakePoint(x, y - 9.0) withAttributes:attrs];
        }
    }

    std::string label = "MEM phys_footprint " + formatBytes(_memoryFootprint) +
        "  virtual " + formatBytes(_memoryVirtual);
    NSDictionary* labelAttrs = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightBold],
                                 NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.82 green:0.96 blue:1.0 alpha:0.72]};
    [nsString(label) drawAtPoint:NSMakePoint(panelX + 8.0, panelY + 5.0) withAttributes:labelAttrs];
}

- (void)drawProcessMap:(NSRect)rect {
    CGFloat panelW = std::min<CGFloat>(620.0, rect.size.width - 36.0);
    CGFloat panelH = std::min<CGFloat>(310.0, rect.size.height - 44.0);
    CGFloat panelX = rect.origin.x + 18.0;
    CGFloat panelY = rect.origin.y + 22.0;

    [[NSColor colorWithCalibratedRed:0.015 green:0.012 blue:0.055 alpha:0.84] setFill];
    NSRectFillUsingOperation(NSMakeRect(panelX, panelY, panelW, panelH), NSCompositingOperationSourceOver);
    [[NSColor colorWithCalibratedHue:0.55 saturation:0.86 brightness:1.0 alpha:0.65] setStroke];
    NSBezierPath* border = [NSBezierPath bezierPathWithRect:NSMakeRect(panelX, panelY, panelW, panelH)];
    [border setLineWidth:1.0];
    [border stroke];

    NSDictionary* titleAttrs = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:13.0 weight:NSFontWeightBold],
                                 NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.86 green:0.98 blue:1.0 alpha:0.95]};
    NSDictionary* attrs = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.74 green:0.88 blue:1.0 alpha:0.88]};
    NSDictionary* hotAttrs = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightBold],
                               NSForegroundColorAttributeName: [NSColor colorWithCalibratedHue:0.14 saturation:0.82 brightness:1.0 alpha:0.95]};

    std::vector<std::string> lines = {
        "PROCESS MAP  Command-I hides/reveals this accountability layer",
        "TOKEN FIELD     total " + std::to_string(_tokenCount) + "  visible " + std::to_string(_visibleTokenCount),
        "BRACKET MOTION  nesting selects 45/90 degree trail directions",
        "EDIT TRACE      insert/delete marks " + std::to_string(_editTraces.size()) + "  lifetime fades over frames",
        "MEMORY          phys " + formatBytes(_memoryFootprint) + "  virtual " + formatBytes(_memoryVirtual),
        "METABOLISM      cpu " + std::to_string(static_cast<int>(std::round(_cpuPercent))) + "%  draw " +
            std::to_string(static_cast<int>(std::round(_lastDrawMs))) + "ms  frame " + std::to_string(_frame),
        "RUNNER          " + std::string(_runnerPid > 0 ? "external sound process active" : "idle"),
        "SELF OBSERVE    " + std::string([self isSelfSource] ? "this view is highlighting its own renderer" : "Command-Y opens renderer source")
    };

    CGFloat y = panelY + 16.0;
    for (std::size_t i = 0; i < lines.size(); ++i) {
        [nsString(lines[i]) drawAtPoint:NSMakePoint(panelX + 16.0, y)
                          withAttributes:i == 0 ? titleAttrs : (i == 4 || i == 5 ? hotAttrs : attrs)];
        y += i == 0 ? 27.0 : 21.0;
    }

    CGFloat mapX = panelX + 18.0;
    CGFloat mapY = panelY + panelH - 82.0;
    CGFloat mapW = panelW - 36.0;
    CGFloat mapH = 48.0;
    std::array<double, 6> signals{{
        std::min(1.0, _visibleTokenCount / 220.0),
        std::min(1.0, _editTraces.size() / 120.0),
        std::min(1.0, _memoryFootprint / (512.0 * 1024.0 * 1024.0)),
        std::min(1.0, _cpuPercent / 120.0),
        _runnerPid > 0 ? 1.0 : 0.0,
        [self isSelfSource] ? 1.0 : 0.0
    }};
    for (std::size_t i = 0; i < signals.size(); ++i) {
        CGFloat x = mapX + i * (mapW / signals.size());
        CGFloat w = mapW / signals.size() - 5.0;
        CGFloat h = mapH * signals[i];
        NSColor* c = [NSColor colorWithCalibratedHue:fmod(0.52 + i * 0.11, 1.0)
                                          saturation:0.86
                                          brightness:0.96
                                               alpha:0.58];
        [c setFill];
        NSRectFillUsingOperation(NSMakeRect(x, mapY + mapH - h, w, h), NSCompositingOperationSourceOver);
    }
}

- (void)drawTopBar:(NSRect)rect {
    [[NSColor colorWithCalibratedRed:0.050 green:0.045 blue:0.180 alpha:0.96] setFill];
    NSRectFill(rect);
    NSColor* stripe = [NSColor colorWithCalibratedHue:fmod(0.82 + _pulse * 0.01, 1.0)
                                           saturation:0.90
                                           brightness:0.95
                                                alpha:1.0];
    [stripe setFill];
    NSRectFill(NSMakeRect(rect.origin.x, rect.origin.y + rect.size.height - 4, rect.size.width, 4));

    NSDictionary* titleAttrs = @{NSFontAttributeName: _boldFont,
                                 NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.94 green:0.96 blue:1.0 alpha:1.0]};
    std::string title = "Source TEXT";
    [nsString(title) drawAtPoint:NSMakePoint(18, 12) withAttributes:titleAttrs];

    NSDictionary* metaAttrs = @{NSFontAttributeName: _font,
                                NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.62 green:0.80 blue:1.0 alpha:1.0]};
    std::string meta = baseName(_filename) + (_dirty ? " *" : "") + "  /  " + languageName(_language);
    meta += "  /  mem " + formatBytes(_memoryFootprint);
    if (_runnerPid > 0) meta += "  /  running";
    [nsString(meta) drawAtPoint:NSMakePoint(170, 14) withAttributes:metaAttrs];
}

- (void)drawCodeArea:(NSRect)rect gutter:(CGFloat)gutterW {
    [[NSColor colorWithCalibratedRed:0.018 green:0.020 blue:0.095 alpha:0.92] setFill];
    NSRectFill(rect);

    for (int y = 0; y < _visibleRows; ++y) {
        int row = _rowoff + y;
        if (row >= static_cast<int>(_rows.size())) continue;
        CGFloat lineY = rect.origin.y + y * _lineH;
        BOOL active = row == _cy;
        if (active) {
            [[NSColor colorWithCalibratedHue:fmod(0.78 + _pulse * 0.01, 1.0)
                                  saturation:0.60
                                  brightness:0.40
                                       alpha:0.48] setFill];
            NSRectFill(NSMakeRect(0, lineY, rect.size.width, _lineH));
        }
    }

    [self drawCodeCellBackgrounds:rect gutter:gutterW];
    [self drawFeedbackOverlay:rect];
    [self drawEditTraces:rect gutter:gutterW];
    [self drawCausalityLabels:rect gutter:gutterW];
    [self drawCodeGlyphs:rect gutter:gutterW];
    [self drawCursorInRect:rect gutter:gutterW];
}

- (void)drawCodeCellBackgrounds:(NSRect)rect gutter:(CGFloat)gutterW {
    CGFloat codeX = gutterW;
    for (int y = 0; y < _visibleRows; ++y) {
        int row = _rowoff + y;
        CGFloat lineY = rect.origin.y + y * _lineH;
        BOOL active = row == _cy;

        if (row >= static_cast<int>(_rows.size())) continue;
        std::vector<Kind> kinds = (row < static_cast<int>(_highlights.size()))
            ? _highlights[row]
            : std::vector<Kind>(_rows[row].size(), Kind::Normal);
        [self overlaySearch:kinds line:_rows[row]];
        [self overlayBracketMatches:kinds row:row];

        int rx = 0;
        for (std::size_t i = 0; i < _rows[row].size(); ++i) {
            char c = _rows[row][i];
            int width = (c == '\t') ? (TAB_STOP - (rx % TAB_STOP)) : 1;
            Kind kind = i < kinds.size() ? kinds[i] : Kind::Normal;
            for (int w = 0; w < width; ++w) {
                if (rx >= _coloff && rx < _coloff + _visibleCols) {
                    CGFloat x = codeX + (rx - _coloff) * _charW;
                    NSRect cell = NSMakeRect(x, lineY, _charW + 1.0, _lineH);
                    [[self colorForKind:kind row:row col:rx background:YES active:active] setFill];
                    NSRectFillUsingOperation(cell, NSCompositingOperationSourceOver);
                }
                ++rx;
            }
        }
    }
}

- (void)drawFeedbackOverlay:(NSRect)rect {
    if (!_feedbackImage) return;
    [NSGraphicsContext saveGraphicsState];
    [NSBezierPath clipRect:rect];
    [_feedbackImage drawInRect:[self bounds]
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationScreen
                      fraction:0.46
                respectFlipped:YES
                         hints:nil];
    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawEditTraces:(NSRect)rect gutter:(CGFloat)gutterW {
    if (_editTraces.empty()) return;
    int now = _frame;
    CGFloat codeX = gutterW;
    for (const EditTrace& trace : _editTraces) {
        int age = now - trace.frame;
        if (age < 0 || age > 180) continue;
        int row = trace.row - _rowoff;
        int col = trace.col - _coloff;
        if (row < -2 || row > _visibleRows + 2 || col < -8 || col > _visibleCols + 8) continue;
        CGFloat life = 1.0 - static_cast<CGFloat>(age) / 180.0;
        CGFloat x = codeX + col * _charW;
        CGFloat y = rect.origin.y + row * _lineH;
        CGFloat drift = age * 0.10;
        NSColor* fill = trace.deletion
            ? [NSColor colorWithCalibratedHue:0.97 saturation:0.88 brightness:0.95 alpha:0.30 * life]
            : [NSColor colorWithCalibratedHue:0.34 saturation:0.86 brightness:1.0 alpha:0.34 * life];
        [fill setFill];
        NSRectFillUsingOperation(NSMakeRect(x - drift, y + drift * (trace.deletion ? 0.45 : -0.20),
                                            _charW * (trace.deletion ? 2.6 : 1.8),
                                            _lineH),
                                 NSCompositingOperationSourceOver);

        char glyph[2] = {std::isprint(static_cast<unsigned char>(trace.ch)) ? trace.ch : '?', '\0'};
        NSDictionary* attrs = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:_fontSize * 0.88 weight:NSFontWeightBold],
                                NSForegroundColorAttributeName: trace.deletion
                                    ? [NSColor colorWithCalibratedRed:1.0 green:0.86 blue:0.94 alpha:0.82 * life]
                                    : [NSColor colorWithCalibratedRed:0.84 green:1.0 blue:0.88 alpha:0.82 * life]};
        [nsString(glyph) drawAtPoint:NSMakePoint(x + drift * 0.35, y + 3.0 - drift * 0.10) withAttributes:attrs];
    }

    _editTraces.erase(std::remove_if(_editTraces.begin(), _editTraces.end(), [now](const EditTrace& trace) {
        return now - trace.frame > 240;
    }), _editTraces.end());
}

- (void)drawCausalityLabels:(NSRect)rect gutter:(CGFloat)gutterW {
    std::array<std::string, 7> labels{{
        "TOKEN",
        "BRACKET",
        "MEM",
        "EDIT",
        "CURSOR",
        "RUNNER",
        "FRAME"
    }};
    uint64_t h = hashString(_filename, _memoryFootprint ^ static_cast<uint64_t>(_frame));
    NSDictionary* attrs = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightBold],
                            NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.78 green:0.92 blue:1.0 alpha:0.32]};
    for (std::size_t i = 0; i < labels.size(); ++i) {
        CGFloat x = gutterW + fmod(static_cast<CGFloat>((h >> (i * 7)) & 0x3FF) / 1024.0 * std::max<CGFloat>(1.0, rect.size.width - gutterW - 90.0) +
                                  _frame * (0.05 + i * 0.015), std::max<CGFloat>(1.0, rect.size.width - gutterW - 90.0));
        CGFloat y = rect.origin.y + 8.0 + fmod(static_cast<CGFloat>((h >> (i * 9 + 3)) & 0x3FF) / 1024.0 * std::max<CGFloat>(1.0, rect.size.height - 26.0) +
                                             _frame * (0.025 + i * 0.008), std::max<CGFloat>(1.0, rect.size.height - 26.0));
        if (labels[i] == "RUNNER" && _runnerPid <= 0) continue;
        [nsString(labels[i]) drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
    }
}

- (void)drawCodeGlyphs:(NSRect)rect gutter:(CGFloat)gutterW {
    CGFloat codeX = gutterW;
    for (int y = 0; y < _visibleRows; ++y) {
        int row = _rowoff + y;
        CGFloat lineY = rect.origin.y + y * _lineH;
        BOOL active = row == _cy;
        if (row >= static_cast<int>(_rows.size())) continue;

        if ([self isSelfSource]) {
            const std::string& sourceLine = _rows[row];
            std::string tag;
            if (sourceLine.find("drawMemoryMap") != std::string::npos) tag = "SELF: MEMORY VISUAL";
            else if (sourceLine.find("updateFeedbackLayer") != std::string::npos) tag = "SELF: FEEDBACK ENGINE";
            else if (sourceLine.find("drawArtBackdrop") != std::string::npos) tag = "SELF: SOURCE TEXTURE";
            else if (sourceLine.find("sampleMemory") != std::string::npos) tag = "SELF: MEMORY SENSOR";
            else if (sourceLine.find("recordEditAtRow") != std::string::npos) tag = "SELF: EDIT TRACE";
            if (!tag.empty()) {
                [[NSColor colorWithCalibratedHue:0.14 saturation:0.92 brightness:1.0 alpha:0.20] setFill];
                NSRectFillUsingOperation(NSMakeRect(gutterW, lineY, rect.size.width - gutterW, _lineH),
                                         NSCompositingOperationSourceOver);
                NSDictionary* tagAttrs = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightBold],
                                           NSForegroundColorAttributeName: [NSColor colorWithCalibratedHue:0.14 saturation:0.50 brightness:1.0 alpha:0.86]};
                [nsString(tag) drawAtPoint:NSMakePoint(std::max<CGFloat>(gutterW + 8.0, rect.size.width - 230.0), lineY + 5.0)
                            withAttributes:tagAttrs];
            }
        }

        NSDictionary* numberAttrs = @{NSFontAttributeName: _font,
                                      NSForegroundColorAttributeName: active
                                          ? [NSColor colorWithCalibratedHue:0.15 saturation:0.90 brightness:1.0 alpha:1.0]
                                          : [NSColor colorWithCalibratedRed:0.54 green:0.64 blue:0.92 alpha:0.95]};
        std::ostringstream n;
        n << row + 1;
        [nsString(n.str()) drawAtPoint:NSMakePoint(12, lineY + 4) withAttributes:numberAttrs];

        std::vector<Kind> kinds = (row < static_cast<int>(_highlights.size()))
            ? _highlights[row]
            : std::vector<Kind>(_rows[row].size(), Kind::Normal);
        [self overlaySearch:kinds line:_rows[row]];
        [self overlayBracketMatches:kinds row:row];

        int rx = 0;
        for (std::size_t i = 0; i < _rows[row].size(); ++i) {
            char c = _rows[row][i];
            int width = (c == '\t') ? (TAB_STOP - (rx % TAB_STOP)) : 1;
            Kind kind = i < kinds.size() ? kinds[i] : Kind::Normal;
            for (int w = 0; w < width; ++w) {
                if (rx >= _coloff && rx < _coloff + _visibleCols && c != '\t' && c != ' ') {
                    CGFloat x = codeX + (rx - _coloff) * _charW;
                    NSFont* font = (kind == Kind::Keyword || kind == Kind::Type || kind == Kind::Builtin ||
                                    kind == Kind::Number || kind == Kind::Symbol)
                        ? _boldFont
                        : _font;
                    NSDictionary* attrs = @{NSFontAttributeName: font,
                                            NSForegroundColorAttributeName: [self colorForKind:kind row:row col:rx background:NO active:active]};
                    char glyph[2] = {std::isprint(static_cast<unsigned char>(c)) ? c : '?', '\0'};
                    [nsString(glyph) drawAtPoint:NSMakePoint(x, lineY + 3) withAttributes:attrs];
                }
                ++rx;
            }
        }
    }
}

- (void)drawCursorInRect:(NSRect)rect gutter:(CGFloat)gutterW {
    int cursorRx = [self rowCxToRx:_cy cx:_cx];
    if (_cy < _rowoff || _cy >= _rowoff + _visibleRows ||
        cursorRx < _coloff || cursorRx >= _coloff + _visibleCols) {
        return;
    }
    CGFloat x = gutterW + (cursorRx - _coloff) * _charW;
    CGFloat y = rect.origin.y + (_cy - _rowoff) * _lineH;
    NSColor* cursor = [NSColor colorWithCalibratedHue:fmod(0.52 + _pulse * 0.06, 1.0)
                                           saturation:0.96
                                           brightness:1.0
                                                alpha:0.92];
    [cursor setStroke];
    NSBezierPath* path = [NSBezierPath bezierPathWithRect:NSMakeRect(x, y + 1, _charW, _lineH - 2)];
    [path setLineWidth:2.0];
    [path stroke];
}

- (void)overlaySearch:(std::vector<Kind>&)kinds line:(const std::string&)line {
    if (_searchTerm.empty()) return;
    std::size_t pos = line.find(_searchTerm);
    while (pos != std::string::npos) {
        markRange(kinds, pos, pos + _searchTerm.size(), Kind::Search);
        pos = line.find(_searchTerm, pos + std::max<std::size_t>(1, _searchTerm.size()));
    }
}

- (void)overlayBracketMatches:(std::vector<Kind>&)kinds row:(int)row {
    if (_matchA && _matchA->row == row && _matchA->col >= 0 && _matchA->col < static_cast<int>(kinds.size())) {
        kinds[_matchA->col] = Kind::Match;
    }
    if (_matchB && _matchB->row == row && _matchB->col >= 0 && _matchB->col < static_cast<int>(kinds.size())) {
        kinds[_matchB->col] = Kind::Match;
    }
}

- (void)drawMinimap:(NSRect)rect {
    [[NSColor colorWithCalibratedRed:0.035 green:0.030 blue:0.130 alpha:1.0] setFill];
    NSRectFill(rect);
    if (_rows.empty()) return;
    CGFloat rowH = std::max<CGFloat>(1.0, rect.size.height / std::max<std::size_t>(1, _rows.size()));
    CGFloat colW = 2.0;
    for (std::size_t r = 0; r < _rows.size(); ++r) {
        CGFloat y = rect.origin.y + r * rowH;
        if (y > rect.origin.y + rect.size.height) break;
        const std::vector<Kind>& kinds = (r < _highlights.size()) ? _highlights[r] : std::vector<Kind>();
        int cols = std::min<int>(static_cast<int>(_rows[r].size()), static_cast<int>((rect.size.width - 8) / colW));
        for (int c = 0; c < cols; ++c) {
            Kind kind = c < static_cast<int>(kinds.size()) ? kinds[c] : Kind::Normal;
            [[self colorForKind:kind row:static_cast<int>(r) col:c background:YES active:NO] setFill];
            NSRectFill(NSMakeRect(rect.origin.x + 4 + c * colW, y, colW, rowH));
        }
    }
    CGFloat viewY = rect.origin.y + _rowoff * rowH;
    CGFloat viewH = std::max<CGFloat>(4.0, _visibleRows * rowH);
    [[NSColor colorWithCalibratedRed:1.0 green:1.0 blue:1.0 alpha:0.25] setStroke];
    NSBezierPath* box = [NSBezierPath bezierPathWithRect:NSMakeRect(rect.origin.x + 2, viewY, rect.size.width - 4, viewH)];
    [box setLineWidth:1.0];
    [box stroke];
}

- (void)drawConsole:(NSRect)rect {
    [[NSColor colorWithCalibratedRed:0.025 green:0.035 blue:0.105 alpha:0.96] setFill];
    NSRectFill(rect);
    NSDictionary* attrs = @{NSFontAttributeName: _font,
                            NSForegroundColorAttributeName: [NSColor colorWithCalibratedHue:0.45 saturation:0.55 brightness:0.92 alpha:1.0]};
    int maxLines = std::max(1, static_cast<int>(floor((rect.size.height - 12) / _lineH)));
    int start = std::max(0, static_cast<int>(_console.size()) - maxLines);
    for (int i = 0; i < maxLines && start + i < static_cast<int>(_console.size()); ++i) {
        [nsString(_console[start + i]) drawAtPoint:NSMakePoint(14, rect.origin.y + 6 + i * _lineH) withAttributes:attrs];
    }
}

- (void)drawStatus:(NSRect)rect {
    NSColor* bg = [NSColor colorWithCalibratedHue:fmod(0.87 + _pulse * 0.015, 1.0)
                                       saturation:0.78
                                       brightness:0.88
                                            alpha:1.0];
    [bg setFill];
    NSRectFill(rect);
    std::ostringstream right;
    right << "Ln " << (_cy + 1) << "  Col " << (_cx + 1);
    std::string text = _status.empty() ? "Ready." : _status;
    NSDictionary* attrs = @{NSFontAttributeName: _boldFont,
                            NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.05 green:0.03 blue:0.11 alpha:1.0]};
    [nsString(text) drawAtPoint:NSMakePoint(16, rect.origin.y + 7) withAttributes:attrs];
    NSSize size = [nsString(right.str()) sizeWithAttributes:attrs];
    [nsString(right.str()) drawAtPoint:NSMakePoint(rect.size.width - size.width - 16, rect.origin.y + 7) withAttributes:attrs];
}

- (void)drawPrompt:(NSRect)rect {
    [[NSColor colorWithCalibratedRed:0.045 green:0.040 blue:0.165 alpha:1.0] setFill];
    NSRectFill(rect);
    [[NSColor colorWithCalibratedHue:0.56 saturation:0.88 brightness:1.0 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, rect.origin.y, rect.size.width, 3));
    std::string prompt = _promptLabel + _promptBuffer;
    NSDictionary* attrs = @{NSFontAttributeName: _boldFont,
                            NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.86 green:0.96 blue:1.0 alpha:1.0]};
    [nsString(prompt) drawAtPoint:NSMakePoint(16, rect.origin.y + 10) withAttributes:attrs];
}

- (void)keyDown:(NSEvent*)event {
    if (_promptMode != PromptMode::None) {
        [self handlePromptKey:event];
        return;
    }

    NSEventModifierFlags flags = [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL command = (flags & NSEventModifierFlagCommand) != 0;
    BOOL control = (flags & NSEventModifierFlagControl) != 0;
    NSString* charsIgnoring = [[event charactersIgnoringModifiers] lowercaseString];
    unichar ch = [charsIgnoring length] > 0 ? [charsIgnoring characterAtIndex:0] : 0;

    if (command || control) {
        switch (ch) {
            case 'n': [self newDocument:nil]; return;
            case 'o': [self openDocument:nil]; return;
            case 's': [self saveDocument:nil]; return;
            case 'f': [self showFind:nil]; return;
            case 'g': [self findNext:YES fromCurrent:NO]; return;
            case 'i':
                _showProcessMap = !_showProcessMap;
                [self setStatus:_showProcessMap ? "Process map visible." : "Process map hidden."];
                return;
            case 'j': [self beginPrompt:PromptMode::Goto label:"Go to line: " initial:""]; return;
            case 'r': [self runBuffer]; return;
            case 't': [self stopRunnerAnnounce:YES]; return;
            case 'l': [self cycleLanguage]; return;
            case 'y': [self openSelf:nil]; return;
            case 'd': [self duplicateLine]; return;
            case 'p': [self showCommand:nil]; return;
            case '/': [self toggleComment]; return;
            case '=':
            case '+': _fontSize = std::min<CGFloat>(42.0, _fontSize + 1.0); [self refreshFont]; [self setNeedsDisplay:YES]; return;
            case '-': _fontSize = std::max<CGFloat>(10.0, _fontSize - 1.0); [self refreshFont]; [self setNeedsDisplay:YES]; return;
            default: break;
        }
    }

    switch ([event keyCode]) {
        case 123: [self moveCursor:0]; return;
        case 124: [self moveCursor:1]; return;
        case 126: [self moveCursor:2]; return;
        case 125: [self moveCursor:3]; return;
        case 115: _cx = 0; [self setNeedsDisplay:YES]; return;
        case 119: _cx = static_cast<int>(_rows[_cy].size()); [self setNeedsDisplay:YES]; return;
        case 116: for (int i = 0; i < _visibleRows; ++i) [self moveCursor:2]; return;
        case 121: for (int i = 0; i < _visibleRows; ++i) [self moveCursor:3]; return;
        case 51: [self backspace]; return;
        case 117: [self deleteChar]; return;
        case 36:
        case 76: [self insertNewline]; return;
        case 48:
            if (flags & NSEventModifierFlagShift) [self outdentLine];
            else [self insertTab];
            return;
        case 53:
            [self setStatus:""];
            return;
        default:
            break;
    }

    NSString* chars = [event characters];
    for (NSUInteger i = 0; i < [chars length]; ++i) {
        unichar uc = [chars characterAtIndex:i];
        if (uc >= 32 && uc < 127) [self insertChar:static_cast<char>(uc)];
    }
}

- (void)handlePromptKey:(NSEvent*)event {
    switch ([event keyCode]) {
        case 53:
            _promptMode = PromptMode::None;
            [self setStatus:"Cancelled."];
            return;
        case 51:
        case 117:
            if (!_promptBuffer.empty()) _promptBuffer.pop_back();
            [self setNeedsDisplay:YES];
            return;
        case 36:
        case 76:
            [self finishPrompt];
            return;
        default:
            break;
    }
    NSString* chars = [event characters];
    for (NSUInteger i = 0; i < [chars length]; ++i) {
        unichar uc = [chars characterAtIndex:i];
        if (uc >= 32 && uc < 127) _promptBuffer += static_cast<char>(uc);
    }
    [self setNeedsDisplay:YES];
}

- (void)beginPrompt:(PromptMode)mode label:(const std::string&)label initial:(const std::string&)initial {
    _promptMode = mode;
    _promptLabel = label;
    _promptBuffer = initial;
    [self setNeedsDisplay:YES];
}

- (void)finishPrompt {
    PromptMode mode = _promptMode;
    std::string value = _promptBuffer;
    _promptMode = PromptMode::None;
    _promptLabel.clear();
    _promptBuffer.clear();

    if (mode == PromptMode::Search) {
        _searchTerm = value;
        if (_searchTerm.empty()) [self setStatus:"Search cleared."];
        else [self findNext:YES fromCurrent:YES];
    } else if (mode == PromptMode::Goto) {
        try {
            int line = std::stoi(value);
            _cy = std::clamp(line - 1, 0, std::max(0, static_cast<int>(_rows.size()) - 1));
            _cx = std::min<int>(_cx, _rows[_cy].size());
        } catch (...) {
            [self setStatus:"That is not a line number."];
        }
    } else if (mode == PromptMode::Command) {
        [self runCommand:value];
    }
    [self setNeedsDisplay:YES];
}

- (void)runCommand:(const std::string&)raw {
    std::string cmd = toLower(trim(raw));
    if (cmd.empty()) return;
    if (cmd == "open" || cmd == "o") [self openDocument:nil];
    else if (cmd == "save" || cmd == "write" || cmd == "w") [self saveDocument:nil];
    else if (cmd == "run" || cmd == "r") [self runBuffer];
    else if (cmd == "stop" || cmd == "t") [self stopRunnerAnnounce:YES];
    else if (cmd == "search" || cmd == "find" || cmd == "f") [self showFind:nil];
    else if (cmd == "process" || cmd == "map" || cmd == "i") {
        _showProcessMap = !_showProcessMap;
        [self setStatus:_showProcessMap ? "Process map visible." : "Process map hidden."];
    }
    else if (cmd == "goto" || cmd == "line" || cmd == "j") [self beginPrompt:PromptMode::Goto label:"Go to line: " initial:""];
    else if (cmd == "lang" || cmd == "language" || cmd == "l") [self cycleLanguage];
    else if (cmd == "self" || cmd == "source" || cmd == "y") [self openSelf:nil];
    else if (cmd == "comment" || cmd == "/") [self toggleComment];
    else if (cmd == "duplicate" || cmd == "dup" || cmd == "d") [self duplicateLine];
    else if (cmd == "new") [self newDocument:nil];
    else [self setStatus:"Unknown command."];
}

- (void)mouseDown:(NSEvent*)event {
    [[self window] makeFirstResponder:self];
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    CGFloat topH = 48.0;
    CGFloat minimapW = 76.0;
    CGFloat gutterW = std::max<CGFloat>(54.0, (std::to_string(std::max<std::size_t>(1, _rows.size())).size() + 2) * _charW);
    if (p.y >= topH && p.x >= [self bounds].size.width - minimapW) {
        CGFloat editorH = std::max<CGFloat>(1.0, [self bounds].size.height - topH - 34.0);
        CGFloat ratio = std::clamp((p.y - topH) / editorH, 0.0, 1.0);
        _cy = std::clamp<int>(ratio * _rows.size(), 0, std::max(0, static_cast<int>(_rows.size()) - 1));
        _cx = std::min<int>(_cx, _rows[_cy].size());
    } else if (p.y >= topH) {
        int row = _rowoff + static_cast<int>((p.y - topH) / _lineH);
        int col = _coloff + std::max(0, static_cast<int>((p.x - gutterW) / _charW));
        if (row >= 0 && row < static_cast<int>(_rows.size())) {
            _cy = row;
            _cx = std::clamp<int>(col, 0, _rows[_cy].size());
        }
    }
    [self setNeedsDisplay:YES];
}

- (void)scrollWheel:(NSEvent*)event {
    if (fabs([event scrollingDeltaX]) > fabs([event scrollingDeltaY])) {
        _coloff = std::max(0, _coloff + static_cast<int>([event scrollingDeltaX] / 8.0));
    } else {
        _rowoff = std::max(0, _rowoff + static_cast<int>([event scrollingDeltaY] / 6.0));
        _rowoff = std::min(_rowoff, std::max(0, static_cast<int>(_rows.size()) - 1));
    }
    [self setNeedsDisplay:YES];
}

- (void)insertChar:(char)c {
    if (isCloseBracket(c) && _cx < static_cast<int>(_rows[_cy].size()) && _rows[_cy][_cx] == c) {
        ++_cx;
        [self setNeedsDisplay:YES];
        return;
    }
    char close = matchingBracket(c);
    if (close && isOpenBracket(c)) {
        _rows[_cy].insert(_cx, std::string{c, close});
        [self recordEditAtRow:_cy col:_cx ch:c deletion:NO];
        [self recordEditAtRow:_cy col:_cx + 1 ch:close deletion:NO];
        ++_cx;
    } else if ((c == '"' || c == '\'') && (_cx >= static_cast<int>(_rows[_cy].size()) || _rows[_cy][_cx] != c)) {
        _rows[_cy].insert(_cx, std::string{c, c});
        [self recordEditAtRow:_cy col:_cx ch:c deletion:NO];
        [self recordEditAtRow:_cy col:_cx + 1 ch:c deletion:NO];
        ++_cx;
    } else {
        _rows[_cy].insert(_rows[_cy].begin() + _cx, c);
        [self recordEditAtRow:_cy col:_cx ch:c deletion:NO];
        ++_cx;
    }
    _dirty = true;
    [self updateWindowTitle];
    [self markHighlightDirty];
}

- (std::string)leadingWhitespace:(const std::string&)line {
    std::size_t i = 0;
    while (i < line.size() && (line[i] == ' ' || line[i] == '\t')) ++i;
    return line.substr(0, i);
}

- (void)insertNewline {
    std::string& line = _rows[_cy];
    std::string left = line.substr(0, _cx);
    std::string right = line.substr(_cx);
    std::string indent = [self leadingWhitespace:left];
    bool bracketSandwich = !left.empty() && !right.empty() && isOpenBracket(left.back()) && right.front() == matchingBracket(left.back());
    if (!left.empty() && std::strchr("{([", left.back()) != nullptr) indent += "  ";
    line = left;
    if (bracketSandwich) {
        std::string closeIndent = [self leadingWhitespace:left];
        _rows.insert(_rows.begin() + _cy + 1, indent);
        _rows.insert(_rows.begin() + _cy + 2, closeIndent + right);
    } else {
        _rows.insert(_rows.begin() + _cy + 1, indent + right);
    }
    ++_cy;
    _cx = static_cast<int>(indent.size());
    [self recordEditAtRow:_cy col:_cx ch:'\n' deletion:NO];
    _dirty = true;
    [self updateWindowTitle];
    [self markHighlightDirty];
}

- (void)insertTab {
    int spaces = TAB_STOP - ([self rowCxToRx:_cy cx:_cx] % TAB_STOP);
    _rows[_cy].insert(_cx, std::string(spaces, ' '));
    [self recordEditAtRow:_cy col:_cx ch:'\t' deletion:NO];
    _cx += spaces;
    _dirty = true;
    [self updateWindowTitle];
    [self markHighlightDirty];
}

- (void)outdentLine {
    int removed = 0;
    while (removed < TAB_STOP && !_rows[_cy].empty() && _rows[_cy].front() == ' ') {
        _rows[_cy].erase(_rows[_cy].begin());
        ++removed;
    }
    if (removed > 0) {
        [self recordEditAtRow:_cy col:0 ch:' ' deletion:YES];
        _cx = std::max(0, _cx - removed);
        _dirty = true;
        [self updateWindowTitle];
        [self markHighlightDirty];
    }
}

- (void)backspace {
    if (_cy == 0 && _cx == 0) return;
    if (_cx > 0) {
        std::string& line = _rows[_cy];
        char before = line[_cx - 1];
        if (isOpenBracket(before) && _cx < static_cast<int>(line.size()) && line[_cx] == matchingBracket(before)) {
            [self recordEditAtRow:_cy col:_cx - 1 ch:before deletion:YES];
            [self recordEditAtRow:_cy col:_cx ch:line[_cx] deletion:YES];
            line.erase(_cx - 1, 2);
            --_cx;
        } else {
            [self recordEditAtRow:_cy col:_cx - 1 ch:line[_cx - 1] deletion:YES];
            line.erase(line.begin() + _cx - 1);
            --_cx;
        }
    } else {
        [self recordEditAtRow:_cy col:0 ch:'\n' deletion:YES];
        _cx = static_cast<int>(_rows[_cy - 1].size());
        _rows[_cy - 1] += _rows[_cy];
        _rows.erase(_rows.begin() + _cy);
        --_cy;
    }
    _dirty = true;
    [self updateWindowTitle];
    [self markHighlightDirty];
}

- (void)deleteChar {
    if (_cx < static_cast<int>(_rows[_cy].size())) {
        [self recordEditAtRow:_cy col:_cx ch:_rows[_cy][_cx] deletion:YES];
        _rows[_cy].erase(_rows[_cy].begin() + _cx);
    } else if (_cy + 1 < static_cast<int>(_rows.size())) {
        [self recordEditAtRow:_cy col:_cx ch:'\n' deletion:YES];
        _rows[_cy] += _rows[_cy + 1];
        _rows.erase(_rows.begin() + _cy + 1);
    } else {
        return;
    }
    _dirty = true;
    [self updateWindowTitle];
    [self markHighlightDirty];
}

- (void)moveCursor:(int)direction {
    if (direction == 0) {
        if (_cx > 0) --_cx;
        else if (_cy > 0) {
            --_cy;
            _cx = static_cast<int>(_rows[_cy].size());
        }
    } else if (direction == 1) {
        if (_cx < static_cast<int>(_rows[_cy].size())) ++_cx;
        else if (_cy + 1 < static_cast<int>(_rows.size())) {
            ++_cy;
            _cx = 0;
        }
    } else if (direction == 2) {
        if (_cy > 0) --_cy;
    } else if (direction == 3) {
        if (_cy + 1 < static_cast<int>(_rows.size())) ++_cy;
    }
    _cx = std::min<int>(_cx, _rows[_cy].size());
    [self setNeedsDisplay:YES];
}

- (void)duplicateLine {
    _rows.insert(_rows.begin() + _cy + 1, _rows[_cy]);
    [self recordEditAtRow:_cy + 1 col:0 ch:'=' deletion:NO];
    ++_cy;
    _dirty = true;
    [self updateWindowTitle];
    [self markHighlightDirty];
    [self setStatus:"Duplicated line."];
}

- (void)toggleComment {
    std::string& line = _rows[_cy];
    std::size_t indent = 0;
    while (indent < line.size() && std::isspace(static_cast<unsigned char>(line[indent]))) ++indent;
    if (line.compare(indent, 2, "//") == 0) {
        line.erase(indent, 2);
        [self recordEditAtRow:_cy col:static_cast<int>(indent) ch:'/' deletion:YES];
        if (_cx >= static_cast<int>(indent + 2)) _cx -= 2;
    } else {
        line.insert(indent, "//");
        [self recordEditAtRow:_cy col:static_cast<int>(indent) ch:'/' deletion:NO];
        [self recordEditAtRow:_cy col:static_cast<int>(indent + 1) ch:'/' deletion:NO];
        if (_cx >= static_cast<int>(indent)) _cx += 2;
    }
    _dirty = true;
    [self updateWindowTitle];
    [self markHighlightDirty];
}

- (void)cycleLanguage {
    switch (_language) {
        case Language::SuperCollider: _language = Language::ChucK; break;
        case Language::ChucK: _language = Language::Cpp; break;
        case Language::Cpp: _language = Language::Plain; break;
        case Language::Plain: _language = Language::SuperCollider; break;
    }
    [self markHighlightDirty];
    [self setStatus:"Language: " + languageName(_language) + "."];
}

- (void)findNext:(BOOL)forward fromCurrent:(BOOL)fromCurrent {
    if (_searchTerm.empty()) {
        [self setStatus:"No search term."];
        return;
    }
    int rowCount = static_cast<int>(_rows.size());
    int startRow = _cy;
    int startCol = fromCurrent ? _cx : (forward ? _cx + 1 : _cx - 1);
    for (int step = 0; step < rowCount; ++step) {
        int row = forward ? (startRow + step) % rowCount : (startRow - step + rowCount) % rowCount;
        const std::string& line = _rows[row];
        if (forward) {
            std::size_t begin = row == startRow ? std::max(0, startCol) : 0;
            std::size_t pos = line.find(_searchTerm, begin);
            if (pos != std::string::npos) {
                _cy = row;
                _cx = static_cast<int>(pos);
                [self setStatus:"Found " + _searchTerm + "."];
                return;
            }
        } else {
            std::size_t begin = (row == startRow && startCol >= 0)
                ? static_cast<std::size_t>(std::min<int>(startCol, line.size()))
                : std::string::npos;
            std::size_t pos = line.rfind(_searchTerm, begin);
            if (pos != std::string::npos) {
                _cy = row;
                _cx = static_cast<int>(pos);
                [self setStatus:"Found " + _searchTerm + "."];
                return;
            }
        }
    }
    [self setStatus:"No match."];
}

- (void)updateBracketMatch {
    _matchA.reset();
    _matchB.reset();
    if (_rows.empty()) return;
    int row = _cy;
    int col = _cx;
    char c = '\0';
    if (col < static_cast<int>(_rows[row].size()) && (isOpenBracket(_rows[row][col]) || isCloseBracket(_rows[row][col]))) {
        c = _rows[row][col];
    } else if (col > 0 && (isOpenBracket(_rows[row][col - 1]) || isCloseBracket(_rows[row][col - 1]))) {
        --col;
        c = _rows[row][col];
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
            while (r < static_cast<int>(_rows.size())) {
                while (cc < static_cast<int>(_rows[r].size())) {
                    char here = _rows[r][cc];
                    if (here == c) ++depth;
                    if (here == target) {
                        if (depth == 0) {
                            _matchA = Position{row, col};
                            _matchB = Position{r, cc};
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
        }
        --cc;
        while (r >= 0) {
            while (cc >= 0) {
                char here = _rows[r][cc];
                if (here == c) ++depth;
                if (here == target) {
                    if (depth == 0) {
                        _matchA = Position{row, col};
                        _matchB = Position{r, cc};
                        return;
                    }
                    --depth;
                }
                --cc;
            }
            --r;
            if (r >= 0) cc = static_cast<int>(_rows[r].size()) - 1;
        }
        return;
    }
}

- (void)runBuffer {
    if (_runnerPid > 0) {
        [self setStatus:"Already running."];
        return;
    }
    if (_filename.empty() || _dirty) {
        if (![self writeCurrentFile]) return;
    }
    std::string exe;
    if (_language == Language::SuperCollider) exe = "sclang";
    else if (_language == Language::ChucK) exe = "chuck";
    else {
        [self setStatus:"Run is configured for SuperCollider and ChucK."];
        return;
    }
    if (!commandExists(exe)) {
        [self setStatus:exe + " was not found in PATH."];
        return;
    }
    std::string command = exe + " " + shellQuote(_filename);
    [self startRunner:command];
}

- (void)startRunner:(const std::string&)command {
    int pipefd[2];
    if (pipe(pipefd) == -1) {
        [self setStatus:"Could not create runner pipe."];
        return;
    }
    pid_t pid = fork();
    if (pid == -1) {
        close(pipefd[0]);
        close(pipefd[1]);
        [self setStatus:"Could not start runner."];
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
    _runnerPid = pid;
    _runnerFd = pipefd[0];
    _runnerPartial.clear();
    [self appendConsole:"$ " + command];
    [self setStatus:"Running. Command-T stops."];
}

- (void)stopRunnerAnnounce:(BOOL)announce {
    if (_runnerPid <= 0) {
        if (announce) [self setStatus:"No running sketch."];
        return;
    }
    kill(_runnerPid, SIGTERM);
    int status = 0;
    waitpid(_runnerPid, &status, 0);
    if (_runnerFd != -1) {
        close(_runnerFd);
        _runnerFd = -1;
    }
    _runnerPid = -1;
    if (announce) {
        [self appendConsole:"[stopped]"];
        [self setStatus:"Stopped."];
    }
}

- (void)tick:(NSTimer*)timer {
    (void)timer;
    double now = [NSDate timeIntervalSinceReferenceDate];
    double delta = std::max(0.001, now - _lastTickTime);
    _lastTickTime = now;
    _pulse += 1.0 / 30.0;
    ++_frame;
    [self sampleCpuWithDelta:delta];
    [self sampleMemory];
    [self pollRunner];
    [self setNeedsDisplay:YES];
}

- (void)pollRunner {
    if (_runnerFd != -1) {
        char buffer[512];
        while (true) {
            ssize_t n = read(_runnerFd, buffer, sizeof(buffer));
            if (n > 0) {
                _runnerPartial.append(buffer, buffer + n);
                [self flushRunnerLines:NO];
            } else {
                break;
            }
        }
    }
    if (_runnerPid > 0) {
        int status = 0;
        pid_t result = waitpid(_runnerPid, &status, WNOHANG);
        if (result == _runnerPid) {
            [self flushRunnerLines:YES];
            if (_runnerFd != -1) {
                close(_runnerFd);
                _runnerFd = -1;
            }
            _runnerPid = -1;
            if (WIFEXITED(status)) [self appendConsole:"[exit " + std::to_string(WEXITSTATUS(status)) + "]"];
            else if (WIFSIGNALED(status)) [self appendConsole:"[signal " + std::to_string(WTERMSIG(status)) + "]"];
            [self setStatus:"Runner finished."];
        }
    }
}

- (void)flushRunnerLines:(BOOL)all {
    std::size_t pos = 0;
    while ((pos = _runnerPartial.find('\n')) != std::string::npos) {
        std::string line = _runnerPartial.substr(0, pos);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        [self appendConsole:line];
        _runnerPartial.erase(0, pos + 1);
    }
    if (all && !_runnerPartial.empty()) {
        [self appendConsole:_runnerPartial];
        _runnerPartial.clear();
    }
}

- (void)appendConsole:(const std::string&)line {
    _console.push_back(line);
    if (_console.size() > 160) _console.erase(_console.begin(), _console.begin() + static_cast<long>(_console.size() - 160));
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate {
    NSWindow* _window;
    SourceTextView* _view;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    NSRect frame = NSMakeRect(80, 80, 1180, 760);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:NSWindowStyleMaskTitled |
                                                    NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskResizable |
                                                    NSWindowStyleMaskMiniaturizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _view = [[SourceTextView alloc] initWithFrame:[[_window contentView] bounds]];
    [_view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [[_window contentView] addSubview:_view];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:_view];

    NSArray<NSString*>* args = [[NSProcessInfo processInfo] arguments];
    if ([args count] > 1) {
        NSString* arg = args[1];
        if ([arg isEqualToString:@"--self"]) {
            [_view openSelf:nil];
        } else if (![arg hasPrefix:@"-"]) {
            [_view loadFileAtPath:arg];
        }
    }

    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return YES;
}

@end

void buildMenu() {
    NSMenu* menubar = [[NSMenu alloc] initWithTitle:@""];
    [NSApp setMainMenu:menubar];

    NSMenuItem* appItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    [menubar addItem:appItem];
    NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"Source TEXT"];
    [appItem setSubmenu:appMenu];
    [appMenu addItemWithTitle:@"Quit Source TEXT" action:@selector(terminate:) keyEquivalent:@"q"];

    NSMenuItem* fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    [menubar addItem:fileItem];
    NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileItem setSubmenu:fileMenu];
    [fileMenu addItemWithTitle:@"New" action:@selector(newDocument:) keyEquivalent:@"n"];
    [fileMenu addItemWithTitle:@"Open..." action:@selector(openDocument:) keyEquivalent:@"o"];
    [fileMenu addItemWithTitle:@"Save" action:@selector(saveDocument:) keyEquivalent:@"s"];
    [fileMenu addItemWithTitle:@"Save As..." action:@selector(saveDocumentAs:) keyEquivalent:@"S"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Open Self Source" action:@selector(openSelf:) keyEquivalent:@"y"];

    NSMenuItem* editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    [menubar addItem:editItem];
    NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editItem setSubmenu:editMenu];
    [editMenu addItemWithTitle:@"Find" action:@selector(showFind:) keyEquivalent:@"f"];
    [editMenu addItemWithTitle:@"Next Match" action:@selector(findNextMenu:) keyEquivalent:@"g"];
    [editMenu addItemWithTitle:@"Command Palette" action:@selector(showCommand:) keyEquivalent:@"p"];

    NSMenuItem* runItem = [[NSMenuItem alloc] initWithTitle:@"Run" action:nil keyEquivalent:@""];
    [menubar addItem:runItem];
    NSMenu* runMenu = [[NSMenu alloc] initWithTitle:@"Run"];
    [runItem setSubmenu:runMenu];
    [runMenu addItemWithTitle:@"Run Sketch" action:@selector(runDocument:) keyEquivalent:@"r"];
    [runMenu addItemWithTitle:@"Stop Sketch" action:@selector(stopRun:) keyEquivalent:@"t"];
}

@interface SourceTextView (MenuActions)
- (void)findNextMenu:(id)sender;
@end

@implementation SourceTextView (MenuActions)
- (void)findNextMenu:(id)sender {
    (void)sender;
    [self findNext:YES fromCurrent:NO];
}
@end

int main(int argc, const char* argv[]) {
    if (argc > 1) {
        std::string arg = argv[1];
        if (arg == "--help" || arg == "-h") {
            std::cout
                << "Source TEXT " << JUICY_VERSION << "\n"
                << "Usage: " << argv[0] << " [file]\n"
                << "       " << argv[0] << " --self\n";
            return 0;
        }
        if (arg == "--version" || arg == "-v") {
            std::cout << JUICY_VERSION << "\n";
            return 0;
        }
    }
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        buildMenu();
        AppDelegate* delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
