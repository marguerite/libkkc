/*
 * Copyright (C) 2011-2013 Daiki Ueno <ueno@gnu.org>
 * Copyright (C) 2011-2013 Red Hat, Inc.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */
using Gee;

namespace Kkc {
    class State : Object {
        internal Type handler_type;
        InputMode _input_mode;
        [CCode(notify = false)]
        internal InputMode input_mode {
            get {
                return _input_mode;
            }
            set {
                var _last_input_mode = _input_mode;
                _input_mode = value;
                if (_input_mode >= KanaMode.HIRAGANA &&
                    _input_mode <= KanaMode.WIDE_LATIN)
                    rom_kana_converter.kana_mode = (KanaMode) _input_mode;
                if (_last_input_mode != _input_mode) {
                    notify_property ("input-mode");
                }
            }
        }

        internal void finish_rom_kana_conversion () {
            rom_kana_converter.flush_partial ();
            input_characters.add_all (rom_kana_converter.produced);
            rom_kana_converter.produced.clear ();
        }

        internal void convert_segment_by_kana_mode (KanaMode mode) {
            int start_char_pos = segments.get_offset (segments.cursor_pos);
            int stop_char_pos = start_char_pos + segments[segments.cursor_pos].input.char_count ();
            var characters = input_characters.slice (start_char_pos, stop_char_pos);
            segments[segments.cursor_pos].output =
                convert_rom_kana_characters_by_kana_mode (characters, mode);
        }

        internal string convert_rom_kana_characters_by_kana_mode (RomKanaCharacterList characters, KanaMode mode) {
            update_latin_conversion_case (mode);

            switch (mode) {
            case KanaMode.HIRAGANA:
            case KanaMode.KATAKANA:
            case KanaMode.HANKAKU_KATAKANA:
                return RomKanaUtils.convert_by_kana_mode (
                    characters.get_output (),
                    mode);
            case KanaMode.LATIN:
            case KanaMode.WIDE_LATIN:
                return RomKanaUtils.convert_by_kana_mode (
                    latin_conversion_upper ?
                    characters.get_input ().up () :
                    characters.get_input (),
                    mode);
            }
            return_val_if_reached (null);
        }

        void update_latin_conversion_case (KanaMode mode) {
            if (mode == KanaMode.LATIN || mode == KanaMode.WIDE_LATIN) {
                if (last_command_key != null && this_command_key != null) {
                    var last_command = lookup_key (last_command_key);
                    var this_command = lookup_key (this_command_key);
                    if (last_command == this_command)
                        latin_conversion_upper = !latin_conversion_upper;
                    else
                        latin_conversion_upper = false;
                } else
                    latin_conversion_upper = false;
            }
        }

        internal Decoder decoder;
        internal SegmentList segments;
        bool segments_changed = false;
        internal CandidateList candidates;
        internal DictionaryList dictionaries;

        internal RomKanaConverter rom_kana_converter;
        internal RomKanaCharacterList input_characters = new RomKanaCharacterList ();

        internal string get_input () {
            if (overriding_input != null)
                return overriding_input;

            var builder = new StringBuilder ();
            builder.append (input_characters.get_output ());
            builder.append (rom_kana_converter.pending_output);
            return builder.str;
        }

        internal bool has_input () {
            return overriding_input != null ||
                input_characters.size > 0 ||
                rom_kana_converter.pending_output.length > 0;
        }

        internal StringBuilder selection = new StringBuilder ();
        internal StringBuilder output = new StringBuilder ();
        internal bool quoted = false;
        internal KeyEvent? this_command_key = null;
        internal KeyEvent? last_command_key = null;
        bool latin_conversion_upper = false;

        internal string? overriding_input = null;
        ArrayList<string> completion = new ArrayList<string> ();
        internal Iterator<string> completion_iterator;

        internal PunctuationStyle punctuation_style {
            get {
                return rom_kana_converter.punctuation_style;
            }
            set {
                rom_kana_converter.punctuation_style = value;
            }
        }

        Rule _typing_rule;
        internal Rule typing_rule {
            get {
                return _typing_rule;
            }
            set {
                _typing_rule = value;
                rom_kana_converter.rule = _typing_rule.rom_kana;
            }
        }

        internal string? lookup_key (KeyEvent key) {
            var keymap = _typing_rule.get_keymap (input_mode);
            return_val_if_fail (keymap != null, null);
            return keymap.lookup_key (key);
        }

        internal State (Decoder decoder, DictionaryList dictionaries) {
            this.decoder = decoder;
            this.dictionaries = dictionaries;
            this.segments = new SegmentList ();
            this.candidates = new CandidateList ();
            this.candidates.round = true;
            this.candidates.notify["cursor-pos"].connect (
                candidates_cursor_pos_changed);
            this.candidates.selected.connect (
                candidates_selected);

            rom_kana_converter = new RomKanaConverter ();

            try {
                var metadata = Rule.find_rule ("default");
                assert (metadata != null);
                _typing_rule = new Rule (metadata);
            } catch (RuleParseError e) {
                warning ("cannot load default rule: %s",
                         e.message);
                assert_not_reached ();
            }

            reset ();
        }

        ~State () {
            reset ();
        }

        void candidates_cursor_pos_changed (Object s, ParamSpec? p) {
            if (segments.cursor_pos >= 0 && candidates.cursor_pos >= 0) {
                var candidate = candidates.get (candidates.cursor_pos);
                if (segments[segments.cursor_pos].output != candidate.output) {
                    segments[segments.cursor_pos].output = candidate.output;
                    segments_changed = true;
                }
            }
        }

        void candidates_selected (Candidate candidate) {
            dictionaries.call (
                typeof (SegmentDictionary),
                true,
                (dictionary) => {
                    var segment_dict = dictionary as SegmentDictionary;
                    segment_dict.select_candidate (candidate);
                    return DictionaryCallbackReturn.CONTINUE;
                });
        }

        void select_sentence_for_dictionary (Dictionary dictionary,
                                             Gee.List<PrefixEntry?> prefixes)
        {
            var sentence_dict = dictionary as SentenceDictionary;
            foreach (var prefix in prefixes) {
                var _segments = segments.to_array ();
                var stop = prefix.offset + prefix.sequence.length;
                _segments = _segments[prefix.offset:stop];
                sentence_dict.select_segments (_segments);
            }
        }

        internal void select_sentence () {
            if (!segments_changed)
                return;

            string[] sequence = new string[segments.size];
            for (var i = 0; i < sequence.length; i++) {
                sequence[i] = segments[i].input;
            }
            var prefixes = SequenceUtils.enumerate_prefixes (
                sequence,
                int.min (2, segments.size),
                int.min (5, segments.size));

            dictionaries.call (typeof (SentenceDictionary),
                               true,
                               (dictionary) => {
                                   select_sentence_for_dictionary (dictionary,
                                                                   prefixes);
                                   return DictionaryCallbackReturn.CONTINUE;
                               });
        }

        internal void reset () {
            // output and input_mode won't change
            handler_type = typeof (InitialStateHandler);
            rom_kana_converter.reset ();
            _typing_rule.get_filter ().reset ();
            segments.clear ();
            segments_changed = false;
            candidates.clear ();
            input_characters.clear ();
            overriding_input = null;
            completion_iterator = null;
            completion.clear ();
            quoted = false;
            latin_conversion_upper = false;
        }

        string? lookup_single_for_dictionary (Dictionary dictionary,
                                              string input)
        {
            var segment_dict = dictionary as SegmentDictionary;
            Candidate[] _candidates;
            Template template;
            template = new SimpleTemplate (input);
            if (segment_dict.lookup_candidates (template.source,
                                                template.okuri,
                                                out _candidates)) {
                return template.expand (_candidates[0].text);
            }
            template = new OkuriganaTemplate (input);
            if (segment_dict.lookup_candidates (template.source,
                                                template.okuri,
                                                out _candidates)) {
                return template.expand (_candidates[0].text);
            }
            return null;
        }

        internal string? lookup_single (string input) {
            var normalized_input = RomKanaUtils.normalize (input);
            string? result = null;
            dictionaries.call (typeof (SegmentDictionary),
                               false,
                               (dictionary) => {
                                   result = lookup_single_for_dictionary (
                                       dictionary,
                                       normalized_input);
                                   if (result != null)
                                       return DictionaryCallbackReturn.REMOVE;
                                   return DictionaryCallbackReturn.CONTINUE;
                               });
            return result;
        }

        internal void lookup (Segment segment) {
            candidates.clear ();

            var normalized_input = RomKanaUtils.normalize (segment.input);
            var original = new Candidate (
                normalized_input,
                false,
                segment.output);
            candidates.add (original);

            // Add Kana candidates first to avoid dupes.
            var kana_candidates = new CandidateList ();
            var enum_class = (EnumClass) typeof (KanaMode).class_ref ();
            for (int i = enum_class.minimum; i <= enum_class.maximum; i++) {
                var enum_value = enum_class.get_value (i);
                if (enum_value != null) {
                    var output = RomKanaUtils.convert_by_kana_mode (
                        normalized_input,
                        (KanaMode) enum_value.value);
                    if (output != original.output) {
                        var candidate = new Candidate (normalized_input,
                                                       false,
                                                       output);
                        kana_candidates.add (candidate);
                    }
                }
            }
            candidates.add_all (kana_candidates.to_array ());

            // Do segment lookup first.
            lookup_template (new NumericTemplate (normalized_input));
            lookup_template (new SimpleTemplate (normalized_input));
            lookup_template (new OkuriganaTemplate (normalized_input));

            // Then, do sentence lookup.
            var _segments = decoder.decode (normalized_input,
                                            10,
                                            new int[0]);
            foreach (var _segment in _segments) {
                var builder = new StringBuilder ();
                while (_segment != null) {
                    builder.append (_segment.output);
                    _segment = _segment.next;
                }
                var sentence = new Candidate (
                    normalized_input,
                    false,
                    builder.str);
                candidates.add (sentence);
            }

            // Move Kana candidates at the end.
            for (var i = 0; i < kana_candidates.size; i++) {
                candidates.remove_at (1);
                candidates.insert (candidates.size, kana_candidates[i]);
            }

            candidates.populated ();
        }

        void lookup_template_for_dictionary (Dictionary dictionary,
                                             Template template)
        {
            var segment_dict = dictionary as SegmentDictionary;
            Candidate[] _candidates;
            if (segment_dict.lookup_candidates (template.source,
                                                template.okuri,
                                                out _candidates)) {
                foreach (var candidate in _candidates) {
                    var text = Expression.eval (candidate.text);
                    candidate.output = template.expand (text);
                    // Annotation may also be an expression.
                    if (candidate.annotation != null) {
                        candidate.annotation = Expression.eval (
                            candidate.annotation);
                    }
                    candidates.add (candidate);
                }
            }
        }

        void lookup_template (Template template) {
            dictionaries.call (typeof (SegmentDictionary),
                               false,
                               (dictionary) => {
                                   lookup_template_for_dictionary (dictionary,
                                                                   template);
                                   return DictionaryCallbackReturn.CONTINUE;
                               });
        }

        internal void convert_sentence (string input,
                                        int[]? constraint = null)
        {
            var normalized_input = RomKanaUtils.normalize (input);
            var _segments = decoder.decode (normalized_input,
                                            1,
                                            constraint ?? new int[0]);
            segments.set_segments (_segments[0]);

            if (constraint == null) {
                apply_constraint (input);
            }

            apply_phrase ();
        }

        void apply_constraint_for_dictionary (Dictionary dictionary,
                                              string input)
        {
            var sentence_dict = dictionary as SentenceDictionary;
            var sequence = Utils.split_utf8 (input);
            var prefixes = SequenceUtils.enumerate_prefixes (
                sequence,
                int.min (4, sequence.length),
                sequence.length);
            var next_offset = 0;
            var next_constraint_index = 0;
            var constraint = new ArrayList<int> ();
            foreach (var prefix in prefixes) {
                if (prefix.offset < next_offset)
                    continue;
                int[] _constraint;
                var _input = string.joinv ("", prefix.sequence);
                if (sentence_dict.lookup_constraint (_input,
                                                     out _constraint)) {
                    assert (_constraint.length > 0);
                    var constraint_index = 0;

                    if (constraint.size > 0) {
                        var last_offset = constraint.get (constraint.size - 1);
                        if (last_offset < _constraint[0] + prefix.offset) {
                            // Fill the gap between the last offset and
                            // the beginning of the constraint.
                            var _offset = 0;
                            for (var i = 0; i < segments.size; i++) {
                                _offset += segments[i].input.char_count ();
                                if (last_offset < _offset &&
                                    _offset < _constraint[0] + prefix.offset) {
                                    constraint.add (_offset);
                                }
                            }
                            next_constraint_index = constraint.size;
                        } else {
                            // Make sure that the found constraint matches
                            // the current constraint.
                            bool found_overlap = false;
                            for (var i = next_constraint_index;
                                 i < constraint.size;
                                 i++) {
                                if (constraint[i]
                                    != _constraint[i - next_constraint_index] + prefix.offset) {
                                    found_overlap = true;
                                    break;
                                }
                                constraint_index++;
                            }
                            if (found_overlap)
                                continue;
                            next_constraint_index++;
                        }
                    } else if (prefix.offset > 0) {
                        // Fill the gap between the first segment and
                        // the beginning of the constraint.
                        var _offset = 0;
                        for (var i = 0; i < segments.size; i++) {
                            _offset += segments[i].input.char_count ();
                            if (_offset < _constraint[0] + prefix.offset) {
                                constraint.add (_offset);
                            }
                        }
                        next_constraint_index = constraint.size;
                    }

                    for (var i = constraint_index; i < _constraint.length; i++)
                        constraint.add (_constraint[i] + prefix.offset);

                    next_offset = _constraint[0] + prefix.offset;
                }
            }
            var _segments = decoder.decode (input,
                                            1,
                                            constraint.to_array ());
#if DEBUG
            print ("constraint: ");
            for (var i = 0; i < constraint.size; i++) {
                print ("%d ", constraint[i]);
                
            }
            print ("\n");
#endif
            segments.set_segments (_segments[0]);
        }

        void apply_constraint (string input) {
            dictionaries.call (typeof (SentenceDictionary),
                               false,
                               (dictionary) => {
                                   apply_constraint_for_dictionary (dictionary,
                                                                    input);
                                   return DictionaryCallbackReturn.CONTINUE;
                               });
        }

        void apply_phrase_for_dictionary (Dictionary dictionary) {
            var sentence_dict = dictionary as SentenceDictionary;
            string[] sequence = new string[segments.size];
            for (var i = 0; i < segments.size; i++) {
                sequence[i] = segments[i].input;
            }
            var prefixes = SequenceUtils.enumerate_prefixes (
                sequence,
                int.min (2, sequence.length),
                int.min (5, sequence.length));
            var offset = 0;
            foreach (var prefix in prefixes) {
                if (prefix.offset < offset)
                    continue;
                string[] _value;
                if (sentence_dict.lookup_phrase (prefix.sequence,
                                                 out _value)) {
                    for (var i = 0; i < _value.length; i++) {
                        segments[prefix.offset + i].output = _value[i];
                    }
                    offset += _value.length;
                }
            }
        }

        void apply_phrase () {
            dictionaries.call (typeof (SentenceDictionary),
                               false,
                               (dictionary) => {
                                   apply_phrase_for_dictionary (dictionary);
                                   return DictionaryCallbackReturn.CONTINUE;
                               });
        }

        internal void resize_segment (int amount) {
            if (segments.cursor_pos >= 0 &&
                segments.cursor_pos < segments.size) {
                // Can't expand the last segment.
                if (amount > 0 && segments.cursor_pos > segments.size - 1)
                    return;
                // Can't shrink the segment to zero-length.
                int segment_size = segments[segments.cursor_pos].input.char_count () + amount;
                if (segment_size <= 0)
                    return;

                int[] constraint = {};
                int offset = 0;
                for (var i = 0; i < segments.cursor_pos; i++) {
                    offset += segments[i].input.char_count ();
                    constraint += offset;
                }

                offset += segment_size;
                constraint += offset;

                string[] output = new string[segments.cursor_pos];
                for (var i = 0; i < output.length; i++)
                    output[i] = segments[i].output;
                int cursor_pos = segments.cursor_pos;
                convert_sentence (segments.get_input (), constraint);
                apply_phrase ();
                segments.cursor_pos = cursor_pos;
                for (var i = 0; i < output.length; i++)
                    segments[i].output = output[i];
                segments_changed = true;
            }
        }

        internal void purge_candidate (Candidate candidate) {
            dictionaries.call (typeof (SegmentDictionary),
                               true,
                               (dictionary) => {
                                   var segment_dict = dictionary as SegmentDictionary;
                                   segment_dict.purge_candidate (candidate);
                                   return DictionaryCallbackReturn.CONTINUE;
                               });
        }

        internal void completion_start (string input) {
            completion.clear ();
            dictionaries.call (typeof (SegmentDictionary),
                               false,
                               (dictionary) => {
                                   var segment_dict = dictionary as SegmentDictionary;
                                   string[] _completion = segment_dict.complete (input);
                                   foreach (var word in _completion) {
                                       completion.add (word);
                                   }
                                   return DictionaryCallbackReturn.CONTINUE;
                               });
            completion.sort ();
            completion_iterator = completion.iterator ();
            if (!completion_iterator.first ()) {
                completion_iterator = null;
            }
        }

        public signal void request_selection_text ();
    }

    interface CommandHandler : Object {
        public abstract bool call (string? command, State state, KeyEvent key);
    }

    delegate bool CommandCallback (string? command,
                                          State state,
                                          KeyEvent key);

    class CallbackCommandHandler : CommandHandler, Object {
        unowned CommandCallback cb;

        public CallbackCommandHandler (CommandCallback cb) {
            this.cb = cb;
        }

        public bool call (string? command,
                          State state,
                          KeyEvent key)
        {
            return this.cb (command, state, key);
        }
    }

    abstract class StateHandler : Object {
        Gee.Map<string, CommandHandler> command_handlers =
            new HashMap<string, CommandHandler> ();
        CommandHandler? default_command_handler = null;

        public void register_command_handler (string? command,
                                              CommandHandler handler)
        {
            if (command != null)
                command_handlers.set (command, handler);
            else
                default_command_handler = handler;
        }

        public void register_command_callback (string? command,
                                               CommandCallback cb)
        {
            register_command_handler (command, new CallbackCommandHandler (cb));
        }

        public bool dispatch_command (State state, KeyEvent key) {
            var command = state.lookup_key (key);
            if (command != null && command_handlers.has_key (command))
                return command_handlers.get (command).call (command,
                                                            state,
                                                            key);
            return default_command_handler.call (command, state, key);
        }

        public abstract bool process_key_event (State state, KeyEvent key);
    }

    class InitialStateHandler : StateHandler {
        class ConvertCommandHandler : CommandHandler, Object {
            KanaMode mode;

            public ConvertCommandHandler (KanaMode mode) {
                this.mode = mode;
            }

            public bool call (string? command, State state, KeyEvent key) {
                if (state.input_characters.size > 0) {
                    state.selection.erase ();
                    state.finish_rom_kana_conversion ();
                    state.overriding_input =
                    state.convert_rom_kana_characters_by_kana_mode (
                        state.input_characters,
                        mode);
                    return true;
                }
                return false;
            }
        }

        construct {
            var enum_class = (EnumClass) typeof (KanaMode).class_ref ();
            for (int i = enum_class.minimum; i <= enum_class.maximum; i++) {
                var enum_value = enum_class.get_value (i);
                if (enum_value != null)
                    register_command_handler (
                        "convert-" + enum_value.value_nick,
                        new ConvertCommandHandler (
                            (KanaMode) enum_value.value));
            }

            register_command_callback ("abort", do_abort);
            register_command_callback ("complete", do_complete);
            register_command_callback ("delete", do_delete);
            register_command_callback ("next-candidate", do_next_candidate);
            register_command_callback ("quote", do_quote);
            register_command_callback ("register", do_register);

            register_command_callback (null, do_);
        }

        bool do_quote (string? command, State state, KeyEvent key) {
            state.quoted = true;
            return true;
        }

        bool do_register (string? command, State state, KeyEvent key) {
            state.request_selection_text ();
            return true;
        }

        bool do_abort (string? command, State state, KeyEvent key) {
            if (state.overriding_input != null) {
                state.overriding_input = null;
                return true;
            }

            if (state.has_input ()) {
                state.reset ();
                return true;
            }

            return false;
        }

        bool do_delete (string? command, State state, KeyEvent key) {
            if (state.overriding_input != null) {
                state.overriding_input = null;
                return true;
            }

            if (state.rom_kana_converter.delete ())
                return true;

            if (state.input_characters.size > 0) {
                state.input_characters.remove_at (
                    state.input_characters.size - 1);
                return true;
            }

            return false;
        }

        bool do_complete (string? command, State state, KeyEvent key) {
            state.finish_rom_kana_conversion ();
            if (state.input_characters.size > 0) {
                if (state.completion_iterator == null)
                    state.completion_start (state.get_input ());

                if (state.completion_iterator != null) {
                    state.overriding_input = state.completion_iterator.get ();
                    if (state.completion_iterator.has_next ())
                        state.completion_iterator.next ();
                }
                return true;
            }
            return false;
        }

        bool do_next_candidate (string? command, State state, KeyEvent key) {
            if (state.input_characters.size == 0)
                return false;

            if (state.selection.len > 0) {
                var input = state.get_input ();
                var segment = new Segment (input, state.selection.str);
                state.selection.erase ();
                state.segments.set_segments (segment);
                state.segments.first_segment ();
                state.lookup (state.segments[state.segments.cursor_pos]);
                state.candidates.first ();
                state.handler_type = typeof (ConvertSegmentStateHandler);
                return true;
            }

            if (state.segments.size == 0) {
                state.finish_rom_kana_conversion ();
                string input = RomKanaUtils.get_hiragana (state.get_input ());

                var output = state.lookup_single (input);
                if (output != null) {
                    var segment = new Segment (input, output);
                    state.segments.set_segments (segment);
                } else {
                    state.convert_sentence (input);
                }
                state.segments.first_segment ();
                state.handler_type = typeof (ConvertSentenceStateHandler);
                return true;
            }

            return true;
        }

        bool do_ (string? command, State state, KeyEvent key) {
            bool retval = false;

            if (state.overriding_input != null) {
                state.output.append (state.get_input ());
                state.overriding_input = null;
                state.reset ();
                retval = true;
            }

            if (command != null && command.has_prefix ("insert-kana-")) {
                var kana = RomKanaUtils.convert_by_kana_mode (
                    command["insert-kana-".length:command.length],
                    (KanaMode) state.input_mode);
                state.input_characters.add (RomKanaCharacter () {
                        output = kana,
                        input = key.unicode.to_string ()
                    });
                return true;
            }

            if ((key.modifiers == 0 ||
                 key.modifiers == Kkc.ModifierType.SHIFT_MASK) &&
                state.rom_kana_converter.is_valid (key.unicode)) {
                if (state.rom_kana_converter.append (key.unicode)) {
                    state.input_characters.add_all (
                        state.rom_kana_converter.produced);
                    state.rom_kana_converter.produced.clear ();
                    return true;
                } else {
                    state.input_characters.add (RomKanaCharacter () {
                            output = key.unicode.to_string (),
                            input = key.unicode.to_string ()
                        });
                    state.rom_kana_converter.produced.clear ();
                    return true;
                }
            }

            state.finish_rom_kana_conversion ();
            var input = state.get_input ();
            state.output.append (input);
            state.reset ();
            return retval || input.length > 0;
        }

        public override bool process_key_event (State state, KeyEvent key) {
            // In the initial state, we need to process some special
            // commands (e.g. quoted insert, input mode switch, etc.)
            // prior to standard commands.
            var command = state.lookup_key (key);

            // Clear completion data set by the last command.
            if (state.last_command_key != null) {
                string last_command = state.lookup_key (state.last_command_key);
                if (last_command == "complete" && command != "complete") {
                    if (state.overriding_input != null) {
                        var builder = new StringBuilder ();
                        builder.append (state.input_characters.get_input ());
                        state.input_characters.clear ();
                        state.input_characters.add (RomKanaCharacter () {
                                output = state.overriding_input,
                                input = builder.str
                            });
                    }
                    state.overriding_input = null;
                    state.completion_iterator = null;
                }
            }

            // Check mode switch events prior to further processing.
            if (command != null && command.has_prefix ("set-input-mode-")) {
                var enum_class = (EnumClass) typeof (InputMode).class_ref ();
                var enum_value = enum_class.get_value_by_nick (
                    command["set-input-mode-".length:command.length]);
                if (enum_value != null) {
                    state.selection.erase ();
                    state.finish_rom_kana_conversion ();
                    state.output.append (state.get_input ());
                    state.reset ();
                    state.input_mode = (InputMode) enum_value.value;
                    return true;
                }
            }

            // Under direct input mode, don't process any keys, except
            // mode switch keys.
            if (state.input_mode == InputMode.DIRECT)
                return false;

            // Quoted insert.
            if (state.quoted &&
                (key.modifiers == 0 ||
                 key.modifiers == Kkc.ModifierType.SHIFT_MASK) &&
                0x20 <= key.unicode && key.unicode < 0x7F) {
                state.finish_rom_kana_conversion ();
                state.input_characters.add (RomKanaCharacter () {
                        output = key.unicode.to_string (),
                        input = key.unicode.to_string ()
                    });
                state.quoted = false;
                return true;
            }

            return dispatch_command (state, key);
        }
    }

    class ConvertSentenceStateHandler : StateHandler {
        class ConvertCommandHandler : CommandHandler, Object {
            KanaMode mode;

            public ConvertCommandHandler (KanaMode mode) {
                this.mode = mode;
            }

            public bool call (string? command, State state, KeyEvent key) {
                state.convert_segment_by_kana_mode (mode);
                return true;
            }
        }

        construct {
            register_command_callback ("next-candidate",
                                       do_start_segment_conversion);
            register_command_callback ("previous-candidate",
                                       do_start_segment_conversion);
            register_command_callback ("purge-candidate",
                                       do_start_segment_conversion);

            register_command_callback (
                "original-candidate",
                (command, state, key) => {
                    var segment = state.segments[state.segments.cursor_pos];
                    segment.output = segment.input;
                    return true;
                });

            register_command_callback (
                "expand-segment",
                (command, state, key) => {
                    if (state.segments.cursor_pos < state.segments.size - 1)
                        state.resize_segment (1);
                    return true;
                });

            register_command_callback (
                "shrink-segment",
                (command, state, key) => {
                    if (state.segments[state.segments.cursor_pos].input.char_count () > 1)
                        state.resize_segment (-1);
                    return true;
                });

            register_command_callback (
                "next-segment",
                (command, state, key) => {
                    state.segments.next_segment ();
                    return true;
                });

            register_command_callback (
                "previous-segment",
                (command, state, key) => {
                    state.segments.previous_segment ();
                    return true;
                });

            register_command_callback ("abort", do_clear_unhandled);
            register_command_callback ("delete", do_clear_unhandled);

            var enum_class = (EnumClass) typeof (KanaMode).class_ref ();
            for (int i = enum_class.minimum; i <= enum_class.maximum; i++) {
                var enum_value = enum_class.get_value (i);
                if (enum_value != null)
                    register_command_handler (
                        "convert-" + enum_value.value_nick,
                        new ConvertCommandHandler (
                            (KanaMode) enum_value.value));
            }

            register_command_callback (
                null,
                (command, state, key) => {
                    state.output.append (state.segments.get_output ());
                    state.select_sentence ();
                    state.reset ();
                    // If the key is not bound or won't be further
                    // processed by InitialStateHandler, update preedit.
                    return command != null || command == "commit" ||
                        !((key.modifiers == 0 ||
                           key.modifiers == Kkc.ModifierType.SHIFT_MASK) &&
                          0x20 <= key.unicode && key.unicode < 0x7F);
                });
        }

        bool do_start_segment_conversion (string? command, State state, KeyEvent key) {
            state.lookup (state.segments[state.segments.cursor_pos]);
            state.candidates.first ();
            state.handler_type = typeof (ConvertSegmentStateHandler);
            return false;
        }

        bool do_clear_unhandled (string? command, State state, KeyEvent key) {
            state.segments.clear ();
            state.handler_type = typeof (InitialStateHandler);
            return true;
        }

        public override bool process_key_event (State state, KeyEvent key) {
            return dispatch_command (state, key);
        }
    }

    class ConvertSegmentStateHandler : StateHandler {
        construct {
            register_command_callback (
                "previous-candidate",
                (command, state, key) => {
                    state.candidates.cursor_up ();
                    return true;
                });

            register_command_callback (
                "next-candidate",
                (command, state, key) => {
                    state.candidates.cursor_down ();
                    return true;
                });

            register_command_callback (
                "purge-candidate",
                (command, state, key) => {
                    if (state.candidates.cursor_pos >= 0) {
                        var candidate = state.candidates.get ();
                        state.purge_candidate (candidate);
                        state.reset ();
                    }
                    return true;
                });

            register_command_callback ("abort", do_clear_unhandled);
            register_command_callback ("next-segment", do_select_unhandled);
            register_command_callback ("previous-segment", do_select_unhandled);
            register_command_callback ("delete", do_clear_unhandled);
            register_command_callback ("original-candidate", do_clear_unhandled);

            var enum_class = (EnumClass) typeof (KanaMode).class_ref ();
            for (int i = enum_class.minimum; i <= enum_class.maximum; i++) {
                var enum_value = enum_class.get_value (i);
                if (enum_value != null)
                    register_command_callback (
                        "convert-" + enum_value.value_nick,
                        do_clear_unhandled);
            }

            register_command_callback (null, do_select_unhandled);
        }

        bool do_select_unhandled (string? command, State state, KeyEvent key) {
            if (state.candidates.cursor_pos >= 0)
                state.candidates.select ();
            state.handler_type = typeof (ConvertSentenceStateHandler);
            return false;
        }

        bool do_clear_unhandled (string? command, State state, KeyEvent key) {
            state.candidates.clear ();
            state.handler_type = typeof (ConvertSentenceStateHandler);
            return false;
        }
                    
        public override bool process_key_event (State state, KeyEvent key) {
            return dispatch_command (state, key);
        }
    }
}
