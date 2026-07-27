import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../library/application/library_controller.dart';
import '../../pronunciation/application/speech_controller.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/presentation/settings_sheet.dart';
import '../application/dictionary_providers.dart';
import 'entry_detail_view.dart';
import 'library_pane.dart';
import 'search_pane.dart';

enum DictionarySection { search, favorites, history }

enum DictionaryLayoutMode { mobile, desktop }

class DictionaryScreen extends ConsumerStatefulWidget {
  const DictionaryScreen({
    required this.layoutMode,
    super.key,
    this.selectedEntryId,
  });

  final DictionaryLayoutMode layoutMode;
  final String? selectedEntryId;

  @override
  ConsumerState<DictionaryScreen> createState() => _DictionaryScreenState();
}

class _DictionaryScreenState extends ConsumerState<DictionaryScreen> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode(debugLabel: 'dictionary-search');
  DictionarySection _section = DictionarySection.search;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleHardwareKeyEvent);
    if (widget.selectedEntryId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKeyEvent);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  bool _handleHardwareKeyEvent(KeyEvent event) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    return _handleKeyEvent(_searchFocusNode, event) == KeyEventResult.handled;
  }

  void _setQuery(String query) {
    _section = DictionarySection.search;
    _searchController.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    ref.read(searchQueryControllerProvider.notifier).submit(query);
    _searchFocusNode.requestFocus();
    setState(() {});
  }

  void _clearSearch() {
    _searchController.clear();
    ref.read(searchQueryControllerProvider.notifier).clear();
    _searchFocusNode.requestFocus();
  }

  Future<void> _openEntry(String entryId) async {
    final query = ref.read(searchQueryControllerProvider).query;
    if (query.isNotEmpty) {
      await ref.read(libraryControllerProvider.notifier).recordSearch(query);
    }
    if (mounted) context.go('/entry/$entryId');
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        !ref.read(settingsControllerProvider).shortcutsEnabled) {
      return KeyEventResult.ignored;
    }

    final keyboard = HardwareKeyboard.instance;
    final primaryModifier = keyboard.isControlPressed || keyboard.isMetaPressed;
    final key = event.logicalKey;
    final composing = _searchController.value.composing;
    final isComposing = composing.isValid && !composing.isCollapsed;

    if ((primaryModifier && key == LogicalKeyboardKey.keyL) ||
        (key == LogicalKeyboardKey.slash && !_searchFocusNode.hasFocus)) {
      _searchFocusNode.requestFocus();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape) {
      if (_searchController.text.isNotEmpty) {
        _clearSearch();
      } else if (widget.selectedEntryId != null) {
        context.go('/');
      }
      return KeyEventResult.handled;
    }

    final hits = ref.read(searchResultsProvider).hits;
    if (!isComposing &&
        (key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.arrowUp) &&
        hits.isNotEmpty) {
      ref
          .read(searchQueryControllerProvider.notifier)
          .moveSelection(
            key == LogicalKeyboardKey.arrowDown ? 1 : -1,
            hits.length,
          );
      return KeyEventResult.handled;
    }

    if (!isComposing && key == LogicalKeyboardKey.enter && hits.isNotEmpty) {
      final index = ref.read(searchQueryControllerProvider).selectedIndex;
      _openEntry(hits[index].entry.id);
      return KeyEventResult.handled;
    }

    if (primaryModifier && key == LogicalKeyboardKey.keyD) {
      final entryId = widget.selectedEntryId;
      if (entryId != null) {
        ref.read(libraryControllerProvider.notifier).toggleFavorite(entryId);
        return KeyEventResult.handled;
      }
    }

    if (key == LogicalKeyboardKey.space && !_searchFocusNode.hasFocus) {
      final entryId = widget.selectedEntryId;
      if (entryId != null) {
        unawaited(_speakEntry(entryId));
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Future<void> _speakEntry(String entryId) async {
    final entry = await ref.read(entryProvider(entryId).future);
    if (entry == null || !mounted) return;

    try {
      await ref.read(speechControllerProvider.notifier).speak(entry.reading);
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('日本語の合成音声を再生しました。')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(speechFailureMessage(error))));
      }
    }
  }

  void _changeSection(DictionarySection section) {
    if (widget.selectedEntryId != null) context.go('/');
    setState(() => _section = section);
    if (section == DictionarySection.search) {
      _searchFocusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: KeyedSubtree(
          key: const Key('dictionary-workspace-continuity'),
          child: widget.layoutMode == DictionaryLayoutMode.desktop
              ? _buildDesktop(context)
              : _buildMobile(context),
        ),
      ),
    );
  }

  Widget _buildMobile(BuildContext context) {
    final selectedEntryId = widget.selectedEntryId;
    if (selectedEntryId != null) {
      return MobileEntryScreen(entryId: selectedEntryId);
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return Scaffold(
        key: const Key('mobile-layout'),
        appBar: CupertinoNavigationBar(
          middle: const Text('ことば'),
          trailing: Tooltip(
            message: '設定',
            child: Semantics(
              key: const Key('settings-button'),
              container: true,
              button: true,
              focusable: true,
              label: '設定',
              onTap: () => showSettingsSurface(context),
              child: ExcludeSemantics(
                child: CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size.square(44),
                  onPressed: () => showSettingsSurface(context),
                  child: const Icon(CupertinoIcons.settings),
                ),
              ),
            ),
          ),
        ),
        body: SafeArea(child: _buildPrimaryPane()),
        bottomNavigationBar: CupertinoTabBar(
          key: const Key('ios-section-tabs'),
          currentIndex: _section.index,
          onTap: (index) => _changeSection(DictionarySection.values[index]),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(CupertinoIcons.search),
              label: '検索',
            ),
            BottomNavigationBarItem(
              icon: Icon(CupertinoIcons.star),
              label: 'お気に入り',
            ),
            BottomNavigationBarItem(
              icon: Icon(CupertinoIcons.clock),
              label: '履歴',
            ),
          ],
        ),
      );
    }

    return Scaffold(
      key: const Key('mobile-layout'),
      body: Column(
        children: [
          _PlatformToolbar(onOpenSettings: () => showSettingsSurface(context)),
          Expanded(child: SafeArea(top: false, child: _buildPrimaryPane())),
        ],
      ),
      bottomNavigationBar: _CompactSectionBar(
        selected: _section,
        onSelected: (index) => _changeSection(DictionarySection.values[index]),
      ),
    );
  }

  Widget _buildDesktop(BuildContext context) {
    return Scaffold(
      key: const Key('desktop-layout'),
      body: Column(
        children: [
          _PlatformToolbar(onOpenSettings: () => showSettingsSurface(context)),
          Expanded(
            child: Row(
              children: [
                _DesktopSidebar(selected: _section, onSelected: _changeSection),
                const VerticalDivider(width: 1),
                SizedBox(
                  key: const Key('desktop-primary-pane'),
                  width: 380,
                  child: _buildPrimaryPane(),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  key: const Key('desktop-detail-pane'),
                  child: widget.selectedEntryId == null
                      ? const _DesktopEmptyDetail()
                      : EntryDetailView(entryId: widget.selectedEntryId!),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrimaryPane() {
    return switch (_section) {
      DictionarySection.search => SearchPane(
        controller: _searchController,
        focusNode: _searchFocusNode,
        onClear: _clearSearch,
        onOpenEntry: _openEntry,
        onUseHistoryQuery: _setQuery,
      ),
      DictionarySection.favorites => LibraryPane(
        mode: LibraryPaneMode.favorites,
        onOpenEntry: _openEntry,
        onUseHistoryQuery: _setQuery,
      ),
      DictionarySection.history => LibraryPane(
        mode: LibraryPaneMode.history,
        onOpenEntry: _openEntry,
        onUseHistoryQuery: _setQuery,
      ),
    };
  }
}

class MobileEntryScreen extends StatelessWidget {
  const MobileEntryScreen({required this.entryId, super.key});

  final String entryId;

  void _goBack(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return Scaffold(
        key: const Key('mobile-layout'),
        appBar: CupertinoNavigationBar(
          leading: Tooltip(
            message: '戻る',
            child: CupertinoNavigationBarBackButton(
              key: const Key('ios-entry-back'),
              onPressed: () => _goBack(context),
            ),
          ),
          middle: const Text('ことば'),
        ),
        body: EntryDetailView(entryId: entryId),
      );
    }

    return Scaffold(
      key: const Key('mobile-layout'),
      body: Column(
        children: [
          _PlatformToolbar(title: 'ことば', onBack: () => _goBack(context)),
          Expanded(child: EntryDetailView(entryId: entryId)),
        ],
      ),
    );
  }
}

class _PlatformToolbar extends StatelessWidget {
  const _PlatformToolbar({
    this.title = 'ことば',
    this.onBack,
    this.onOpenSettings,
  });

  final String title;
  final VoidCallback? onBack;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              const SizedBox(width: 8),
              if (onBack != null)
                IconButton(
                  tooltip: '戻る',
                  onPressed: onBack,
                  icon: Icon(
                    defaultTargetPlatform == TargetPlatform.macOS
                        ? Icons.chevron_left
                        : Icons.arrow_back,
                  ),
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (onOpenSettings != null)
                Semantics(
                  key: const Key('settings-button'),
                  container: true,
                  button: true,
                  focusable: true,
                  label: '設定',
                  onTap: onOpenSettings,
                  child: ExcludeSemantics(
                    child: IconButton(
                      tooltip: '設定',
                      onPressed: onOpenSettings,
                      icon: Icon(
                        defaultTargetPlatform == TargetPlatform.macOS
                            ? Icons.tune
                            : Icons.settings_outlined,
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({required this.selected, required this.onSelected});

  final DictionarySection selected;
  final ValueChanged<DictionarySection> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const Key('desktop-platform-sidebar'),
      width: defaultTargetPlatform == TargetPlatform.macOS ? 184 : 176,
      color: colors.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionButton(
            section: DictionarySection.search,
            selected: selected == DictionarySection.search,
            icon: Icons.search,
            label: '検索',
            onPressed: onSelected,
          ),
          const SizedBox(height: 4),
          _SectionButton(
            section: DictionarySection.favorites,
            selected: selected == DictionarySection.favorites,
            icon: Icons.star_outline,
            selectedIcon: Icons.star,
            label: 'お気に入り',
            onPressed: onSelected,
          ),
          const SizedBox(height: 4),
          _SectionButton(
            section: DictionarySection.history,
            selected: selected == DictionarySection.history,
            icon: Icons.history,
            label: '履歴',
            onPressed: onSelected,
          ),
        ],
      ),
    );
  }
}

class _CompactSectionBar extends StatelessWidget {
  const _CompactSectionBar({required this.selected, required this.onSelected});

  final DictionarySection selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        key: const Key('compact-platform-navigation'),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          children: [
            for (final section in DictionarySection.values)
              Expanded(
                child: _SectionButton(
                  section: section,
                  selected: selected == section,
                  icon: switch (section) {
                    DictionarySection.search => Icons.search,
                    DictionarySection.favorites => Icons.star_outline,
                    DictionarySection.history => Icons.history,
                  },
                  selectedIcon: section == DictionarySection.favorites
                      ? Icons.star
                      : null,
                  label: switch (section) {
                    DictionarySection.search => '検索',
                    DictionarySection.favorites => 'お気に入り',
                    DictionarySection.history => '履歴',
                  },
                  compact: true,
                  onPressed: (value) => onSelected(value.index),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionButton extends StatefulWidget {
  const _SectionButton({
    required this.section,
    required this.selected,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selectedIcon,
    this.compact = false,
  });

  final DictionarySection section;
  final bool selected;
  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final ValueChanged<DictionarySection> onPressed;
  final bool compact;

  @override
  State<_SectionButton> createState() => _SectionButtonState();
}

class _SectionButtonState extends State<_SectionButton> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = widget.selected || _focused;
    final background = widget.selected
        ? colors.secondaryContainer
        : _hovered || _focused
        ? colors.surfaceContainerHighest
        : Colors.transparent;

    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      onTap: () => widget.onPressed(widget.section),
      child: ExcludeSemantics(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: FocusableActionDetector(
            onShowFocusHighlight: (value) => setState(() => _focused = value),
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onPressed(widget.section);
                  return null;
                },
              ),
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onPressed(widget.section),
              child: AnimatedContainer(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 100),
                constraints: BoxConstraints(
                  minHeight: widget.compact ? 48 : 40,
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: widget.compact ? 6 : 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(7),
                  border: active
                      ? Border.all(
                          color: colors.primary.withValues(alpha: 0.35),
                        )
                      : null,
                ),
                child: widget.compact
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            widget.selected
                                ? widget.selectedIcon ?? widget.icon
                                : widget.icon,
                            size: 20,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Icon(
                            widget.selected
                                ? widget.selectedIcon ?? widget.icon
                                : widget.icon,
                            size: 19,
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(widget.label)),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopEmptyDetail extends StatelessWidget {
  const _DesktopEmptyDetail();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_outlined, size: 48),
            SizedBox(height: 16),
            Text('言葉を選んでください'),
            SizedBox(height: 8),
            Text('意味や例文をここに表示します。'),
          ],
        ),
      ),
    );
  }
}
