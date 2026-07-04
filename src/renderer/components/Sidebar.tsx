import { memo } from 'react';
import { Search, Plus, Settings, FileText, ChevronRight } from 'lucide-react';
import { Note } from '../../shared/types';

interface SidebarProps {
  notes: Note[];
  activeNoteId?: string;
  searchQuery: string;
  onSearch: (query: string) => void;
  onSelectNote: (note: Note) => void;
  onCreateNote: () => void;
  onOpenSettings: () => void;
}

function formatDate(dateString: string): string {
  const date = new Date(dateString);
  const now = new Date();
  const diff = now.getTime() - date.getTime();
  const days = Math.floor(diff / (1000 * 60 * 60 * 24));

  if (days === 0) {
    return 'Today';
  } else if (days === 1) {
    return 'Yesterday';
  } else if (days < 7) {
    return `${days} days ago`;
  } else {
    return date.toLocaleDateString('en-US', {
      month: 'short',
      day: 'numeric',
      year: date.getFullYear() !== now.getFullYear() ? 'numeric' : undefined,
    });
  }
}

function extractPreview(content: string): string {
  // Strip HTML and get first 100 chars
  const stripped = content.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
  return stripped.substring(0, 80) || 'No content';
}

function Sidebar({
  notes,
  activeNoteId,
  searchQuery,
  onSearch,
  onSelectNote,
  onCreateNote,
  onOpenSettings,
}: SidebarProps) {
  return (
    <nav className="sidebar" aria-label="Notes">
      <div className="sidebar-header">
        <div className="sidebar-title">
          <FileText size={24} aria-hidden="true" />
          Noschen
        </div>
        <div className="search-wrapper">
          <Search size={16} aria-hidden="true" />
          <input
            type="text"
            className="search-input"
            placeholder="Search notes..."
            aria-label="Search notes"
            value={searchQuery}
            onChange={(e) => onSearch(e.target.value)}
          />
        </div>
        <button className="new-note-btn" onClick={onCreateNote}>
          <Plus size={16} aria-hidden="true" />
          New Note
        </button>
      </div>
      <div className="note-list" role="listbox" aria-label="Note list">
        {notes.length === 0 ? (
          <div style={{ padding: '24px 12px', textAlign: 'center', color: 'var(--text-muted)', fontSize: 'var(--font-size-sm)' }}>
            {searchQuery ? 'No notes found' : 'No notes yet'}
          </div>
        ) : (
          <div className="note-list-group">
            {notes.map((note) => (
              <div
                key={note.id}
                className={`note-item ${activeNoteId === note.id ? 'active' : ''}`}
                onClick={() => onSelectNote(note)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    onSelectNote(note);
                  }
                }}
                role="option"
                aria-selected={activeNoteId === note.id}
                tabIndex={0}
              >
                <div className="note-item-title">{note.title || 'Untitled Note'}</div>
                <div className="note-item-preview">
                  <span className="note-item-meta">{formatDate(note.updatedAt)}</span>
                  {extractPreview(note.content)}
                </div>
                <ChevronRight className="note-item-chevron" size={16} aria-hidden="true" />
              </div>
            ))}
          </div>
        )}
      </div>
      <div className="sidebar-footer">
        <button
          className="editor-header-btn"
          style={{ width: '100%', justifyContent: 'center' }}
          onClick={onOpenSettings}
        >
          <Settings size={14} aria-hidden="true" />
          AI Settings
        </button>
      </div>
    </nav>
  );
}

export default memo(Sidebar);
