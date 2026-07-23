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

class DictionaryScreen extends ConsumerStatefulWidget {
  const DictionaryScreen({super.key, this.selectedEntryId});

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

    final hits = ref.read(searchResultsProvider).asData?.value ?? const [];
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
        ref.read(entryProvider(entryId).future).then((entry) {
          if (entry != null) {
            ref.read(speechControllerProvider.notifier).speak(entry.headword);
          }
        });
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 840) return _buildDesktop(context);
            return _buildMobile(context);
          },
        ),
      ),
    );
  }

  Widget _buildMobile(BuildContext context) {
    final selectedEntryId = widget.selectedEntryId;
    if (selectedEntryId != null) {
      return Scaffold(
        key: const Key('mobile-layout'),
        appBar: AppBar(
          leading: IconButton(
            tooltip: '戻る',
            onPressed: () => context.go('/'),
            icon: const Icon(Icons.arrow_back),
          ),
          title: const Text('ことば'),
        ),
        body: EntryDetailView(entryId: selectedEntryId),
      );
    }

    return Scaffold(
      key: const Key('mobile-layout'),
      appBar: AppBar(
        title: const Text('ことば'),
        actions: [
          IconButton(
            key: const Key('settings-button'),
            tooltip: '設定',
            onPressed: () => showSettingsSheet(context),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SafeArea(child: _buildPrimaryPane()),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _section.index,
        onDestinationSelected: (index) =>
            _changeSection(DictionarySection.values[index]),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.search), label: '検索'),
          NavigationDestination(
            icon: Icon(Icons.star_outline),
            selectedIcon: Icon(Icons.star),
            label: 'お気に入り',
          ),
          NavigationDestination(icon: Icon(Icons.history), label: '履歴'),
        ],
      ),
    );
  }

  Widget _buildDesktop(BuildContext context) {
    return Scaffold(
      key: const Key('desktop-layout'),
      appBar: AppBar(
        title: const Text('ことば'),
        actions: [
          IconButton(
            key: const Key('settings-button'),
            tooltip: '設定',
            onPressed: () => showSettingsSheet(context),
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _section.index,
            onDestinationSelected: (index) =>
                _changeSection(DictionarySection.values[index]),
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.search),
                label: Text('検索'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.star_outline),
                selectedIcon: Icon(Icons.star),
                label: Text('お気に入り'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.history),
                label: Text('履歴'),
              ),
            ],
          ),
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
