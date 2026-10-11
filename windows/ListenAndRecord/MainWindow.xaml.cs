using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using ListenAndRecord.Core;
using ListenAndRecord.Recording;
using ListenAndRecord.Transcription;
using Microsoft.Win32;

namespace ListenAndRecord;

public partial class MainWindow : Window
{
    private static readonly (string Code, string Name)[] Languages =
    [
        ("ru", "Русский"), ("auto", "Определять автоматически"), ("en", "English"), ("uk", "Українська"),
        ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"),
        ("kk", "Қазақша"), ("be", "Беларуская"), ("pl", "Polski"),
    ];

    private readonly AppSettings _settings = AppSettings.Current;
    private readonly CallRecorder _recorder = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private bool _loading = true;
    private bool _exporting;

    private string? _inputPath;
    private Transcript? _transcript;
    private string? _savedTranscriptPath;
    private CancellationTokenSource? _transcribeCts;
    private DateTime _transcribeStarted;
    private double _transcribeProgress;

    private readonly Dictionary<string, CancellationTokenSource> _downloads = new();
    private readonly Dictionary<string, double> _downloadProgress = new();
    private readonly Dictionary<string, ProgressBar> _downloadBars = new();

    public MainWindow()
    {
        InitializeComponent();

        foreach (var (ext, title) in AudioExporter.Formats) FormatCombo.Items.Add(new ComboBoxItem { Content = title, Tag = ext });
        foreach (var (code, name) in Languages) LanguageCombo.Items.Add(new ComboBoxItem { Content = name, Tag = code });

        MicCheck.IsChecked = _settings.CaptureMicrophone;
        SysCheck.IsChecked = _settings.CaptureSystemAudio;
        SelectByTag(FormatCombo, _settings.AudioFormat);
        SelectByTag(LanguageCombo, _settings.Language);
        (_settings.TranscriptFormat == "txt" ? TxtRadio : DocxRadio).IsChecked = true;
        TimestampsCheck.IsChecked = _settings.IncludeTimestamps;
        (_settings.EffectiveHighAccuracy ? AccurateRadio : FastRadio).IsChecked = true;
        VadCheck.IsChecked = _settings.UseVad;
        RecoverCheck.IsChecked = _settings.RecoverGaps;

        HardwareText.Text = Hardware.Summary;
        var rec = ModelManager.Catalog.First(m => m.Id == Hardware.RecommendedModelId);
        RecommendationText.Text = Hardware.IsWeak
            ? $"Рекомендуется модель «{rec.Title}» и режим «Быстрее»: процессор без AVX2 или мало памяти. Расшифровка часа записи может занять 1–3 часа."
            : $"Рекомендуется модель «{rec.Title}» и режим «Максимальная точность».";

        _recorder.Finished = CallRecorder.FindUnsaved();
        _recorder.CaptureError += msg => Dispatcher.BeginInvoke(() => ShowError(msg));
        if (_recorder.Finished != null) FileNameBox.Text = DefaultName(_recorder.Finished.StartedAt);

        _timer.Tick += (_, _) => Tick();
        _timer.Start();
        _loading = false;

        RefreshModels();
        UpdateRecordUi();
        UpdateVadUi();
    }

    // ===================== Recording =====================

    private void Start_Click(object sender, RoutedEventArgs e) => StartRecording();
    private void Pause_Click(object sender, RoutedEventArgs e) { _recorder.TogglePause(); UpdateRecordUi(); }
    private void Stop_Click(object sender, RoutedEventArgs e) => StopRecording();

    private void StartRecording()
    {
        if (_recorder.State != RecorderState.Idle) return;
        if (_recorder.HasUnsaved)
        {
            ShowError("Сначала сохраните или удалите предыдущую запись.");
            return;
        }
        try
        {
            HideError();
            _recorder.Start(MicCheck.IsChecked == true, SysCheck.IsChecked == true);
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
        UpdateRecordUi();
    }

    private void StopRecording()
    {
        var finished = _recorder.Stop();
        if (finished != null) FileNameBox.Text = DefaultName(finished.StartedAt);
        UpdateRecordUi();
    }

    private static string DefaultName(DateTime d) => $"Созвон {TimeFormat.FileStamp(d)}";

    private void UpdateRecordUi()
    {
        var state = _recorder.State;
        bool active = state != RecorderState.Idle;
        StartButton.Visibility = active ? Visibility.Collapsed : Visibility.Visible;
        PauseButton.Visibility = StopButton.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        PauseButton.Content = state == RecorderState.Paused ? "▶  Продолжить" : "❚❚  Пауза";
        StartButton.IsEnabled = !_recorder.HasUnsaved;
        MicCheck.IsEnabled = SysCheck.IsEnabled = !active;
        StatusDot.Fill = state switch
        {
            RecorderState.Recording => Brushes.Red,
            RecorderState.Paused => Brushes.Orange,
            _ => Brushes.Gray,
        };
        StatusText.Text = state switch
        {
            RecorderState.Recording => "Идёт запись",
            RecorderState.Paused => "Пауза",
            _ => _recorder.HasUnsaved ? "Запись остановлена — сохраните её" : "Готово к записи",
        };
        Title = state switch
        {
            RecorderState.Recording => "● Запись — ListenAndRecord",
            RecorderState.Paused => "❚❚ Пауза — ListenAndRecord",
            _ => "ListenAndRecord",
        };

        var finished = _recorder.Finished;
        SaveCard.Visibility = !active && finished != null ? Visibility.Visible : Visibility.Collapsed;
        if (finished != null)
        {
            DurationText.Text = "Длительность: " + TimeFormat.Clock(finished.Duration);
            SavedPanel.Visibility = finished.SavedTo != null ? Visibility.Visible : Visibility.Collapsed;
            SavedText.Text = finished.SavedTo != null ? "✔ Сохранено: " + finished.SavedTo : "";
            DiscardButton.Content = finished.SavedTo == null ? "Удалить запись" : "Закрыть";
        }
        SaveButtons.Visibility = _exporting ? Visibility.Collapsed : Visibility.Visible;
        ExportProgress.Visibility = _exporting ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Tick()
    {
        TimerText.Text = TimeFormat.Clock(_recorder.Elapsed);
        MicMeter.Value = Meter(_recorder.MicLevel, MicMeter.Value);
        SysMeter.Value = Meter(_recorder.SystemLevel, SysMeter.Value);
        if (_transcribeCts != null && _transcribeProgress > 0.15)
        {
            var elapsed = (DateTime.Now - _transcribeStarted).TotalSeconds;
            var remaining = elapsed / _transcribeProgress * (1 - _transcribeProgress);
            EtaText.Text = $"{_transcribeProgress:P0} · осталось ≈ {TimeFormat.Human(remaining)}";
        }
        else if (_transcribeCts != null)
        {
            EtaText.Text = $"{_transcribeProgress:P0}";
        }
    }

    private static double Meter(float rms, double previous)
    {
        double value = rms <= 0 ? 0 : Math.Clamp((20 * Math.Log10(rms) + 55) / 55, 0, 1);
        return Math.Max(value, previous * 0.7);
    }

    private async void Save_Click(object sender, RoutedEventArgs e)
    {
        var finished = _recorder.Finished;
        if (finished == null || _exporting) return;
        var format = (FormatCombo.SelectedItem as ComboBoxItem)?.Tag as string ?? "m4a";
        var dialog = new SaveFileDialog
        {
            Title = "Сохранить запись созвона",
            FileName = Sanitize(FileNameBox.Text) + "." + format,
            Filter = format switch
            {
                "mp3" => "MP3 (*.mp3)|*.mp3",
                "wav" => "WAV (*.wav)|*.wav",
                _ => "M4A (*.m4a)|*.m4a",
            },
            AddExtension = true,
            OverwritePrompt = true,
        };
        if (_settings.LastSaveDirectory is string dir && Directory.Exists(dir)) dialog.InitialDirectory = dir;
        if (dialog.ShowDialog(this) != true) return;
        var path = dialog.FileName;
        _settings.LastSaveDirectory = Path.GetDirectoryName(path);
        _settings.Save();

        _exporting = true;
        ExportProgress.Value = 0;
        HideError();
        UpdateRecordUi();
        try
        {
            await Task.Run(() => AudioExporter.Export(finished.Tracks, format, path,
                p => Dispatcher.BeginInvoke(() => ExportProgress.Value = p)));
            _recorder.MarkSaved(path);
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
        finally
        {
            _exporting = false;
            UpdateRecordUi();
        }
    }

    private static string Sanitize(string name)
    {
        foreach (var c in Path.GetInvalidFileNameChars()) name = name.Replace(c, '-');
        name = name.Trim();
        return name.Length == 0 ? DefaultName(DateTime.Now) : name;
    }

    private void Discard_Click(object sender, RoutedEventArgs e)
    {
        var finished = _recorder.Finished;
        if (finished == null) return;
        if (finished.SavedTo == null &&
            MessageBox.Show(this, "Удалить несохранённую запись? Это действие нельзя отменить.", "ListenAndRecord",
                MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
        _recorder.Discard();
        TimerText.Text = TimeFormat.Clock(0);
        UpdateRecordUi();
    }

    private void ShowSaved_Click(object sender, RoutedEventArgs e) => ShowInExplorer(_recorder.Finished?.SavedTo);

    private void TranscribeSaved_Click(object sender, RoutedEventArgs e)
    {
        if (_recorder.Finished?.SavedTo is not string path) return;
        SelectInput(path);
        Tabs.SelectedItem = TranscribeTab;
    }

    private void Sources_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _settings.CaptureMicrophone = MicCheck.IsChecked == true;
        _settings.CaptureSystemAudio = SysCheck.IsChecked == true;
        _settings.Save();
    }

    private void Format_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        _settings.AudioFormat = (FormatCombo.SelectedItem as ComboBoxItem)?.Tag as string ?? "m4a";
        _settings.Save();
    }

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorCard.Visibility = Visibility.Visible;
    }

    private void HideError() => ErrorCard.Visibility = Visibility.Collapsed;
    private void HideError_Click(object sender, RoutedEventArgs e) => HideError();

    // ===================== Transcription =====================

    private void ChooseFile_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Выберите аудио- или видеофайл",
            Filter = "Аудио и видео|*.m4a;*.mp3;*.wav;*.wma;*.aac;*.flac;*.ogg;*.mp4;*.m4v;*.mov;*.wmv;*.avi;*.webm|Все файлы|*.*",
        };
        if (_settings.LastSaveDirectory is string dir && Directory.Exists(dir)) dialog.InitialDirectory = dir;
        if (dialog.ShowDialog(this) == true) SelectInput(dialog.FileName);
    }

    private void DropArea_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) && _transcribeCts == null ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private void DropArea_Drop(object sender, DragEventArgs e)
    {
        if (_transcribeCts != null) return;
        if (e.Data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } files) SelectInput(files[0]);
    }

    private async void SelectInput(string path)
    {
        if (_transcribeCts != null) return;
        _inputPath = path;
        _transcript = null;
        ResultCard.Visibility = Visibility.Collapsed;
        TranscribeError.Visibility = Visibility.Collapsed;
        FileText.Text = Path.GetFileName(path);
        FileInfoText.Text = Path.GetDirectoryName(path);
        var duration = await Task.Run(() => AudioPreparer.Duration(path));
        if (_inputPath == path && duration is double d) FileInfoText.Text = "Длительность: " + TimeFormat.Clock(d);
        UpdateTranscribeUi();
    }

    private void UpdateTranscribeUi()
    {
        bool running = _transcribeCts != null;
        bool hasModel = SelectedModelPath() != null;
        NoModelCard.Visibility = hasModel ? Visibility.Collapsed : Visibility.Visible;
        TranscribeButton.IsEnabled = !running && hasModel && _inputPath != null;
        TranscribeButton.Visibility = running ? Visibility.Collapsed : Visibility.Visible;
        CancelButton.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
        ProgressPanel.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
        OptionsCard.IsEnabled = !running;
        ChooseFileButton.IsEnabled = !running;
    }

    private string? SelectedModelPath()
    {
        var name = _settings.SelectedModel;
        if (string.IsNullOrEmpty(name)) return null;
        var path = ModelManager.PathFor(name);
        return File.Exists(path) ? path : null;
    }

    private async void Transcribe_Click(object sender, RoutedEventArgs e)
    {
        if (_inputPath == null || SelectedModelPath() is not string model) return;
        bool useVad = _settings.UseVad && ModelManager.VadInstalled;
        var whisper = new WhisperSettings(model, useVad ? ModelManager.VadPath : null, _settings.Language,
            Hardware.Threads, _settings.EffectiveHighAccuracy ? 5 : 1);
        var pipeline = new TranscriptionPipeline(whisper, useVad, _settings.RecoverGaps);

        _transcribeCts = new CancellationTokenSource();
        _transcribeStarted = DateTime.Now;
        _transcribeProgress = 0;
        _savedTranscriptPath = null;
        TranscribeProgress.Value = 0;
        StageText.Text = "Запуск…";
        EtaText.Text = "";
        TranscribeError.Visibility = Visibility.Collapsed;
        ResultCard.Visibility = Visibility.Collapsed;
        UpdateTranscribeUi();
        try
        {
            var source = _inputPath;
            var token = _transcribeCts.Token;
            _transcript = await Task.Run(() => pipeline.RunAsync(source, stage => Dispatcher.BeginInvoke(() =>
            {
                if (_transcribeCts == null) return;
                StageText.Text = stage.Title;
                _transcribeProgress = Math.Max(_transcribeProgress, stage.Fraction);
                TranscribeProgress.Value = _transcribeProgress;
            }), token), token);
            ShowTranscript();
        }
        catch (OperationCanceledException)
        {
            TranscribeError.Text = "Расшифровка отменена.";
            TranscribeError.Visibility = Visibility.Visible;
        }
        catch (Exception ex)
        {
            TranscribeError.Text = ex.Message;
            TranscribeError.Visibility = Visibility.Visible;
        }
        finally
        {
            _transcribeCts?.Dispose();
            _transcribeCts = null;
            UpdateTranscribeUi();
        }
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => _transcribeCts?.Cancel();

    private void ShowTranscript()
    {
        if (_transcript == null) return;
        ResultBox.Text = TranscriptExporter.PlainText(_transcript, _settings.IncludeTimestamps);
        WordsText.Text = $"{_transcript.WordCount} слов";
        ShowTranscriptButton.Visibility = Visibility.Collapsed;
        ResultCard.Visibility = Visibility.Visible;
    }

    private void SaveTranscript_Click(object sender, RoutedEventArgs e)
    {
        if (_transcript == null || _inputPath == null) return;
        bool docx = _settings.TranscriptFormat != "txt";
        var dialog = new SaveFileDialog
        {
            Title = "Сохранить расшифровку",
            FileName = Path.GetFileNameWithoutExtension(_inputPath) + (docx ? ".docx" : ".txt"),
            Filter = docx ? "Документ Word (*.docx)|*.docx" : "Текст (*.txt)|*.txt",
            InitialDirectory = Path.GetDirectoryName(_inputPath),
            OverwritePrompt = true,
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            TranscriptExporter.Save(_transcript, dialog.FileName, docx, _settings.IncludeTimestamps);
            _savedTranscriptPath = dialog.FileName;
            ShowTranscriptButton.Visibility = Visibility.Visible;
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Не удалось сохранить файл: " + ex.Message, "ListenAndRecord");
        }
    }

    private void ShowTranscript_Click(object sender, RoutedEventArgs e) => ShowInExplorer(_savedTranscriptPath);

    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        if (_transcript != null) Clipboard.SetText(_transcript.PlainText);
    }

    private void Language_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        _settings.Language = (LanguageCombo.SelectedItem as ComboBoxItem)?.Tag as string ?? "ru";
        _settings.Save();
    }

    private void Model_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || ModelCombo.SelectedItem is not ComboBoxItem { Tag: string file }) return;
        if (_settings.SelectedModel == file) return;
        _settings.SelectedModel = file;
        _settings.Save();
        RefreshModels();
    }

    private void TranscriptFormat_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _settings.TranscriptFormat = TxtRadio.IsChecked == true ? "txt" : "docx";
        _settings.Save();
    }

    private void Timestamps_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _settings.IncludeTimestamps = TimestampsCheck.IsChecked == true;
        _settings.Save();
        if (_transcript != null) ResultBox.Text = TranscriptExporter.PlainText(_transcript, _settings.IncludeTimestamps);
    }

    private void OpenModels_Click(object sender, RoutedEventArgs e) => Tabs.SelectedItem = ModelsTab;

    // ===================== Models =====================

    private void RefreshModels()
    {
        var installed = ModelManager.InstalledFiles();
        if (!installed.Contains(_settings.SelectedModel))
        {
            var recommended = ModelManager.Catalog.First(m => m.Id == Hardware.RecommendedModelId).FileName;
            _settings.SelectedModel = installed.Contains(recommended) ? recommended : installed.FirstOrDefault() ?? "";
            _settings.Save();
        }

        _downloadBars.Clear();
        ModelsList.Children.Clear();
        foreach (var model in ModelManager.Catalog) ModelsList.Children.Add(ModelRow(model.FileName, model));
        foreach (var file in installed.Where(f => ModelManager.Catalog.All(m => m.FileName != f)))
            ModelsList.Children.Add(ModelRow(file, null));

        _loading = true;
        ModelCombo.Items.Clear();
        foreach (var file in installed)
        {
            var item = new ComboBoxItem { Content = ModelManager.TitleFor(file), Tag = file };
            ModelCombo.Items.Add(item);
            if (file == _settings.SelectedModel) ModelCombo.SelectedItem = item;
        }
        _loading = false;
        UpdateTranscribeUi();
    }

    private UIElement ModelRow(string file, ModelInfo? model)
    {
        bool installed = File.Exists(ModelManager.PathFor(file));
        var grid = new Grid { Margin = new Thickness(0, 6, 0, 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var radio = new RadioButton
        {
            GroupName = "model",
            IsEnabled = installed,
            IsChecked = installed && _settings.SelectedModel == file,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 10, 0),
            ToolTip = "Использовать эту модель",
        };
        radio.Checked += (_, _) =>
        {
            if (_settings.SelectedModel == file) return;
            _settings.SelectedModel = file;
            _settings.Save();
            RefreshModels();
        };
        grid.Children.Add(radio);

        var info = new StackPanel();
        var title = new StackPanel { Orientation = Orientation.Horizontal };
        title.Children.Add(new TextBlock { Text = model?.Title ?? file, FontWeight = FontWeights.SemiBold });
        if (model?.Id == Hardware.RecommendedModelId)
        {
            title.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromRgb(0xFD, 0xE2, 0xE2)),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(6, 1, 6, 1),
                Margin = new Thickness(8, 0, 0, 0),
                Child = new TextBlock { Text = "рекомендуется для этого ПК", FontSize = 11, Foreground = (Brush)FindResource("Accent") },
            });
        }
        info.Children.Add(title);
        info.Children.Add(new TextBlock
        {
            Text = model != null ? $"{model.SizeText} · {model.Note}" : "Добавлена вручную",
            Style = (Style)FindResource("Hint"),
        });
        Grid.SetColumn(info, 1);
        grid.Children.Add(info);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (model != null && _downloads.ContainsKey(model.Id))
        {
            var bar = new ProgressBar { Width = 140, Maximum = 1, Value = _downloadProgress.GetValueOrDefault(model.Id), Margin = new Thickness(0, 0, 8, 0) };
            _downloadBars[model.Id] = bar;
            actions.Children.Add(bar);
            var cancel = new Button { Content = "Отмена" };
            cancel.Click += (_, _) => _downloads.GetValueOrDefault(model.Id)?.Cancel();
            actions.Children.Add(cancel);
        }
        else if (installed)
        {
            var delete = new Button { Content = "Удалить" };
            delete.Click += (_, _) =>
            {
                if (MessageBox.Show(this, $"Удалить модель «{model?.Title ?? file}»?", "ListenAndRecord",
                        MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
                ModelManager.Delete(file);
                RefreshModels();
            };
            actions.Children.Add(delete);
        }
        else if (model != null)
        {
            var download = new Button { Content = "Скачать" };
            download.Click += (_, _) => DownloadModel(model);
            actions.Children.Add(download);
        }
        Grid.SetColumn(actions, 2);
        grid.Children.Add(actions);

        return new Border
        {
            BorderBrush = (Brush)FindResource("CardBorder"),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Child = grid,
        };
    }

    private async void DownloadModel(ModelInfo model)
    {
        if (_downloads.ContainsKey(model.Id)) return;
        var cts = new CancellationTokenSource();
        _downloads[model.Id] = cts;
        _downloadProgress[model.Id] = 0;
        ModelsError.Visibility = Visibility.Collapsed;
        RefreshModels();
        var progress = new Progress<double>(p =>
        {
            _downloadProgress[model.Id] = p;
            if (_downloadBars.TryGetValue(model.Id, out var bar)) bar.Value = p;
        });
        try
        {
            await ModelManager.DownloadAsync(model.Url, model.FileName, progress, cts.Token);
            if (SelectedModelPath() == null || model.Id == Hardware.RecommendedModelId)
            {
                _settings.SelectedModel = model.FileName;
                _settings.Save();
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            ModelsError.Text = $"Не удалось скачать «{model.Title}»: {ex.Message}";
            ModelsError.Visibility = Visibility.Visible;
        }
        finally
        {
            _downloads.Remove(model.Id);
            _downloadProgress.Remove(model.Id);
            cts.Dispose();
            RefreshModels();
        }
    }

    private async void ImportModel_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = "Выберите файл модели Whisper (ggml-*.bin)", Filter = "Модели ggml (*.bin)|*.bin" };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            var name = await ModelManager.ImportAsync(dialog.FileName);
            _settings.SelectedModel = name;
            _settings.Save();
        }
        catch (Exception ex)
        {
            ModelsError.Text = "Не удалось добавить модель: " + ex.Message;
            ModelsError.Visibility = Visibility.Visible;
        }
        RefreshModels();
    }

    private void UpdateVadUi()
    {
        bool installed = ModelManager.VadInstalled;
        VadStatus.Text = installed ? "✔ Модель Silero VAD установлена" : "Модель Silero VAD не установлена";
        VadDownloadButton.Visibility = installed ? Visibility.Collapsed : Visibility.Visible;
    }

    private async void DownloadVad_Click(object sender, RoutedEventArgs e)
    {
        VadDownloadButton.IsEnabled = false;
        VadStatus.Text = "Скачивание…";
        try
        {
            await ModelManager.DownloadAsync(ModelManager.VadUrl, ModelManager.VadFileName, new Progress<double>(), CancellationToken.None);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Не удалось скачать модель Silero VAD: " + ex.Message, "ListenAndRecord");
        }
        VadDownloadButton.IsEnabled = true;
        UpdateVadUi();
    }

    private void Accuracy_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _settings.HighAccuracy = AccurateRadio.IsChecked == true;
        _settings.Save();
    }

    private void Vad_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _settings.UseVad = VadCheck.IsChecked == true;
        _settings.Save();
    }

    private void Recover_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _settings.RecoverGaps = RecoverCheck.IsChecked == true;
        _settings.Save();
    }

    private void OpenMicPrivacy_Click(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true });

    // ===================== Helpers =====================

    private static void SelectByTag(ComboBox combo, string tag)
    {
        foreach (ComboBoxItem item in combo.Items)
            if ((string?)item.Tag == tag) { combo.SelectedItem = item; return; }
        combo.SelectedIndex = 0;
    }

    private static void ShowInExplorer(string? path)
    {
        if (path == null || !File.Exists(path)) return;
        Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
    }

    // ===================== Global hotkeys & closing =====================

    private const int WmHotkey = 0x0312;
    private const uint ModAlt = 0x1, ModControl = 0x2, ModNoRepeat = 0x4000;
    private const int HotkeyStart = 1, HotkeyPause = 2, HotkeyStop = 3;

    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var handle = new WindowInteropHelper(this).Handle;
        RegisterHotKey(handle, HotkeyStart, ModControl | ModAlt | ModNoRepeat, 0x52);  // R
        RegisterHotKey(handle, HotkeyPause, ModControl | ModAlt | ModNoRepeat, 0x50);  // P
        RegisterHotKey(handle, HotkeyStop, ModControl | ModAlt | ModNoRepeat, 0x53);   // S
        HwndSource.FromHwnd(handle)?.AddHook(WndProc);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WmHotkey) return IntPtr.Zero;
        switch (wParam.ToInt32())
        {
            case HotkeyStart: StartRecording(); break;
            case HotkeyPause: _recorder.TogglePause(); UpdateRecordUi(); break;
            case HotkeyStop: StopRecording(); break;
        }
        handled = true;
        return IntPtr.Zero;
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (_recorder.State != RecorderState.Idle)
        {
            if (MessageBox.Show(this, "Идёт запись созвона. Остановить её и выйти? Запись можно будет сохранить при следующем запуске.",
                    "ListenAndRecord", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            {
                e.Cancel = true;
                return;
            }
            _recorder.Stop();
        }
        _transcribeCts?.Cancel();
        foreach (var cts in _downloads.Values) cts.Cancel();
        base.OnClosing(e);
    }

    protected override void OnClosed(EventArgs e)
    {
        var handle = new WindowInteropHelper(this).Handle;
        UnregisterHotKey(handle, HotkeyStart);
        UnregisterHotKey(handle, HotkeyPause);
        UnregisterHotKey(handle, HotkeyStop);
        base.OnClosed(e);
    }
}
