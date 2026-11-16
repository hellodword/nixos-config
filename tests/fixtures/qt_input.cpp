#include <QApplication>
#include <QInputMethodEvent>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLineEdit>
#include <QSaveFile>
#include <QTextStream>

class Input : public QLineEdit {
    QString preedit;
    void record() {
        QSaveFile state("/run/user/1000/ime-state.json");
        if (!state.open(QIODevice::WriteOnly)) qFatal("Cannot open input observation");
        state.write(QJsonDocument(QJsonObject{{"focused", hasFocus()},
            {"preedit", preedit}, {"text", text()}}).toJson());
        if (!state.commit()) qFatal("Cannot publish input observation");
    }
    void focusInEvent(QFocusEvent *event) override {
        QLineEdit::focusInEvent(event);
        record();
    }
    void focusOutEvent(QFocusEvent *event) override {
        QLineEdit::focusOutEvent(event);
        record();
    }
    void inputMethodEvent(QInputMethodEvent *event) override {
        QLineEdit::inputMethodEvent(event);
        preedit = event->preeditString();
        record();
    }
public:
    Input() {
        setWindowTitle("Native-input-check");
        setPlaceholderText("Input method check");
        resize(500, 80);
        connect(this, &QLineEdit::textChanged, this, [this] { record(); });
        connect(this, &QLineEdit::returnPressed, this, [this] {
            QTextStream(stdout) << text() << Qt::endl;
            QApplication::quit();
        });
    }
};

int main(int argc, char **argv) {
    QApplication application(argc, argv);
    Input input;
    input.show();
    input.activateWindow();
    input.setFocus();
    return application.exec();
}
