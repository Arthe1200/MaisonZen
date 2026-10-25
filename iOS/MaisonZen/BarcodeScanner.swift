import AVFoundation
import SwiftUI

struct BarcodeScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { let controller = ScannerController(); controller.onCode = onCode; return controller }
    func updateUIViewController(_ controller: ScannerController, context: Context) { controller.onCode = onCode }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { showMessage("Caméra indisponible"); return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput(); guard session.canAddOutput(output) else { showMessage("Scanner indisponible"); return }
        session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.ean8, .ean13, .upce, .code128]
        let layer = AVCaptureVideoPreviewLayer(session: session); layer.videoGravity = .resizeAspectFill; layer.frame = view.bounds; view.layer.addSublayer(layer); preview = layer
        let label = UILabel(); label.text = "Place le code-barres dans le cadre"; label.textColor = .white; label.textAlignment = .center; label.backgroundColor = UIColor.black.withAlphaComponent(0.5); label.frame = CGRect(x: 20, y: 50, width: view.bounds.width - 40, height: 48); label.autoresizingMask = [.flexibleWidth]; view.addSubview(label)
        let close = UIButton(type: .system); close.setTitle("Fermer", for: .normal); close.tintColor = .white; close.backgroundColor = UIColor.black.withAlphaComponent(0.55); close.layer.cornerRadius = 12; close.frame = CGRect(x: view.bounds.width - 92, y: view.bounds.height - 72, width: 76, height: 42); close.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin]; close.addTarget(self, action: #selector(closeScanner), for: .touchUpInside); view.addSubview(close)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in DispatchQueue.main.async { if allowed { self?.session.startRunning() } else { self?.showMessage("Autorise l’accès à la caméra dans Réglages.") } } }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) { guard !delivered, let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let value = code.stringValue else { return }; delivered = true; session.stopRunning(); onCode?(value) }
    @objc private func closeScanner() { session.stopRunning(); dismiss(animated: true) }
    private func showMessage(_ text: String) { let label = UILabel(); label.text = text; label.textColor = .white; label.textAlignment = .center; label.numberOfLines = 0; label.frame = view.bounds.insetBy(dx: 24, dy: 24); label.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(label) }
}
